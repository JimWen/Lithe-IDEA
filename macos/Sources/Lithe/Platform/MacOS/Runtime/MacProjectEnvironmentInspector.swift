import Foundation

/// macOS platform adapter that inspects Go, Rust, and Python project SDKs,
/// environment variables, dependency caches, and lazy External Libraries directory trees.
/// All external probes are strictly bounded (3 seconds) and execute off the MainActor.
struct MacProjectEnvironmentInspector: ProjectEnvironmentInspecting {
    private static let probeTimeoutMilliseconds = 3_000
    private static let maxDirectoryEntries = 400
    private static let ignoredDirectoryNames: Set<String> = [
        ".git", ".DS_Store", "__pycache__", ".pytest_cache", ".mypy_cache"
    ]

    private let processRunner: any ProcessRunner
    private let homeDirectoryURL: URL

    init(
        processRunner: any ProcessRunner,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.processRunner = processRunner
        self.homeDirectoryURL = homeDirectoryURL.standardizedFileURL
    }

    func cancelInspection(operationID: String) {
        processRunner.cancel(operationID: "\(operationID):go-env")
        processRunner.cancel(operationID: "\(operationID):rustc-ver")
        processRunner.cancel(operationID: "\(operationID):rustc-sysroot")
        processRunner.cancel(operationID: "\(operationID):python-env")
    }

    func inspectGo(
        workspaceURL: URL,
        manifestURL: URL?,
        executableURL: URL?,
        environment: [String: String],
        operationID: String
    ) -> GoProjectEnvironmentSnapshot {
        var goEnv: [String: String] = [:]
        if let executableURL {
            let workingDirectory = manifestURL?.deletingLastPathComponent().path ?? workspaceURL.path
            let result = processRunner.run(ProcessRequest(
                operationID: "\(operationID):go-env",
                executablePath: executableURL.path,
                arguments: ["env", "-json", "GOROOT", "GOPATH", "GOMODCACHE", "GOPROXY", "GOPRIVATE", "GOVERSION"],
                workingDirectory: workingDirectory,
                environment: environment,
                timeoutMilliseconds: Self.probeTimeoutMilliseconds
            ))
            if result.exitCode == 0,
               let data = result.output.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                goEnv = parsed
            }
        }

        let goRoot = nonEmpty(goEnv["GOROOT"]) ?? nonEmpty(environment["GOROOT"])
        let goPath = nonEmpty(goEnv["GOPATH"]) ?? nonEmpty(environment["GOPATH"])
            ?? homeDirectoryURL.appendingPathComponent("go").path
        let firstGoPath = goPath.split(separator: ":").first.map(String.init) ?? goPath
        let goModCache = nonEmpty(goEnv["GOMODCACHE"]) ?? nonEmpty(environment["GOMODCACHE"])
            ?? URL(fileURLWithPath: firstGoPath).appendingPathComponent("pkg/mod").path
        let goProxy = nonEmpty(goEnv["GOPROXY"]) ?? nonEmpty(environment["GOPROXY"])
        let goPrivate = nonEmpty(goEnv["GOPRIVATE"]) ?? nonEmpty(environment["GOPRIVATE"])
        let version = nonEmpty(goEnv["GOVERSION"])

        let stdLibURL: URL? = goRoot.flatMap { root in
            let src = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("src", isDirectory: true).standardizedFileURL
            return isDirectory(src) ? src : nil
        }

        let targetManifest = manifestURL ?? findFirstFile(named: "go.mod", in: workspaceURL)
        var moduleName: String?
        var goDirective: String?
        var dependencies: [ProjectDependencyItem] = []
        if let targetManifest,
           let content = try? String(contentsOf: targetManifest, encoding: .utf8) {
            let parsed = ProjectDependencyParsers.parseGoMod(content)
            moduleName = parsed.moduleName
            goDirective = parsed.goDirective
            dependencies = ProjectDependencyParsers.resolveGoDependencies(
                parsed: parsed,
                manifestURL: targetManifest,
                goModCache: goModCache,
                directoryExists: { isDirectory($0) }
            )
        }

        return GoProjectEnvironmentSnapshot(
            executablePath: executableURL?.path,
            version: version,
            goRoot: goRoot,
            goPath: goPath,
            goModCache: goModCache,
            goProxy: goProxy,
            goPrivate: goPrivate,
            stdLibURL: stdLibURL,
            moduleName: moduleName,
            goDirective: goDirective,
            manifestURL: targetManifest,
            dependencies: dependencies
        )
    }

    func inspectRust(
        workspaceURL: URL,
        manifestURL: URL?,
        cargoURL: URL?,
        environment: [String: String],
        operationID: String
    ) -> RustProjectEnvironmentSnapshot {
        let cargoHome = nonEmpty(environment["CARGO_HOME"])
            ?? homeDirectoryURL.appendingPathComponent(".cargo").path
        let rustupHome = nonEmpty(environment["RUSTUP_HOME"])
            ?? homeDirectoryURL.appendingPathComponent(".rustup").path
        let workingDirectory = manifestURL?.deletingLastPathComponent().path ?? workspaceURL.path

        let rustcURL: URL? = cargoURL.flatMap { cargo in
            let sibling = cargo.deletingLastPathComponent().appendingPathComponent("rustc")
            return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
        }

        var rustcVersion: String?
        var sysrootPath: String?
        if let rustcURL {
            let verResult = processRunner.run(ProcessRequest(
                operationID: "\(operationID):rustc-ver",
                executablePath: rustcURL.path,
                arguments: ["--version"],
                workingDirectory: workingDirectory,
                environment: environment,
                timeoutMilliseconds: Self.probeTimeoutMilliseconds
            ))
            if verResult.exitCode == 0 {
                rustcVersion = nonEmpty(verResult.output.split(whereSeparator: \.isNewline).first.map(String.init))
            }

            let sysResult = processRunner.run(ProcessRequest(
                operationID: "\(operationID):rustc-sysroot",
                executablePath: rustcURL.path,
                arguments: ["--print", "sysroot"],
                workingDirectory: workingDirectory,
                environment: environment,
                timeoutMilliseconds: Self.probeTimeoutMilliseconds
            ))
            if sysResult.exitCode == 0 {
                sysrootPath = nonEmpty(sysResult.output.split(whereSeparator: \.isNewline).first.map(String.init))
            }
        }

        let activeToolchain: String? = nonEmpty(environment["RUSTUP_TOOLCHAIN"])
            ?? sysrootPath.map { URL(fileURLWithPath: $0).lastPathComponent }

        let stdLibURL: URL? = sysrootPath.flatMap { sysroot in
            let candidate = URL(fileURLWithPath: sysroot, isDirectory: true)
                .appendingPathComponent("lib/rustlib/src/rust/library", isDirectory: true)
                .standardizedFileURL
            return isDirectory(candidate) ? candidate : nil
        }

        let targetManifest = manifestURL ?? findFirstFile(named: "Cargo.toml", in: workspaceURL)
        var crateName: String?
        var dependencies: [ProjectDependencyItem] = []

        if let targetManifest,
           let content = try? String(contentsOf: targetManifest, encoding: .utf8) {
            let parsed = ProjectDependencyParsers.parseCargoToml(content)
            crateName = parsed.crateName
            let manifestDir = targetManifest.deletingLastPathComponent().standardizedFileURL

            // Look for Cargo.lock next to Cargo.toml or at workspace root.
            let lockCandidates = [
                manifestDir.appendingPathComponent("Cargo.lock"),
                workspaceURL.appendingPathComponent("Cargo.lock")
            ]
            var lockPackages: [ProjectDependencyParsers.CargoLockPackage] = []
            for lockURL in lockCandidates {
                if let lockText = try? String(contentsOf: lockURL, encoding: .utf8) {
                    lockPackages = ProjectDependencyParsers.parseCargoLockPackages(lockText)
                    break
                }
            }

            let srcRoot = URL(fileURLWithPath: cargoHome, isDirectory: true)
                .appendingPathComponent("registry/src", isDirectory: true)
            let registrySrcRoots: [URL] = ((try? FileManager.default.contentsOfDirectory(
                at: srcRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []).filter { isDirectory($0) }

            dependencies = parsed.dependencies.map { dep in
                let lockedVersion = ProjectDependencyParsers.resolveCargoLockedVersion(
                    packageName: dep.packageName,
                    versionRequirement: dep.versionRequirement,
                    ownerCrateName: crateName,
                    lockPackages: lockPackages
                )
                let versionDisplay = lockedVersion ?? dep.versionRequirement
                var resolvedURL: URL?
                var replaceTarget: String?
                if let localPath = dep.localPath, !localPath.isEmpty {
                    replaceTarget = localPath
                    let candidate = localPath.hasPrefix("/")
                        ? URL(fileURLWithPath: localPath, isDirectory: true).standardizedFileURL
                        : manifestDir.appendingPathComponent(localPath, isDirectory: true).standardizedFileURL
                    if isDirectory(candidate) { resolvedURL = candidate }
                } else if let lockedVersion {
                    let folderName = "\(dep.packageName)-\(lockedVersion)"
                    for regRoot in registrySrcRoots {
                        let candidate = regRoot.appendingPathComponent(folderName, isDirectory: true).standardizedFileURL
                        if isDirectory(candidate) {
                            resolvedURL = candidate
                            break
                        }
                    }
                }
                return ProjectDependencyItem(
                    id: "cargo:\(dep.name):\(dep.isDevOrBuild ? "dev" : "dep"):\(versionDisplay)",
                    name: dep.name,
                    version: versionDisplay,
                    isDirect: !dep.isDevOrBuild,
                    replaceTarget: replaceTarget,
                    sourceDirectoryURL: resolvedURL,
                    manifestURL: targetManifest
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirect != rhs.isDirect { return lhs.isDirect }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }

        return RustProjectEnvironmentSnapshot(
            cargoPath: cargoURL?.path,
            rustcPath: rustcURL?.path,
            rustcVersion: rustcVersion,
            activeToolchain: activeToolchain,
            cargoHome: cargoHome,
            rustupHome: rustupHome,
            sysrootPath: sysrootPath,
            stdLibURL: stdLibURL,
            crateName: crateName,
            manifestURL: targetManifest,
            dependencies: dependencies
        )
    }

    func inspectPython(
        workspaceURL: URL,
        manifestURL: URL?,
        pythonURL: URL?,
        environment: [String: String],
        operationID: String
    ) -> PythonProjectEnvironmentSnapshot {
        var version: String?
        var prefixPath: String?
        var basePrefixPath: String?
        var stdLibURL: URL?
        var sitePackagesURLs: [URL] = []
        var isVenv = false

        if let pythonURL {
            let probeScript = """
            import json, sys, sysconfig
            paths = []
            for key in ("purelib", "platlib"):
                p = sysconfig.get_path(key)
                if p and p not in paths:
                    paths.append(p)
            print(json.dumps({
                "version": ".".join(map(str, sys.version_info[:3])),
                "prefix": sys.prefix,
                "base_prefix": getattr(sys, "base_prefix", sys.prefix),
                "stdlib": sysconfig.get_path("stdlib") or "",
                "site_packages": paths,
            }))
            """
            // Run Python in isolated mode (`-I`) from `/` so untrusted workspace modules
            // (e.g., a repo-local `json.py` or `sysconfig.py`) or `PYTHONPATH` entries
            // can never execute during passive project inspection. Python still reads
            // `pyvenv.cfg` next to the interpreter binary in `-I` mode.
            let result = processRunner.run(ProcessRequest(
                operationID: "\(operationID):python-env",
                executablePath: pythonURL.path,
                arguments: ["-I", "-c", probeScript],
                workingDirectory: "/",
                environment: environment,
                timeoutMilliseconds: Self.probeTimeoutMilliseconds
            ))
            if result.exitCode == 0,
               let line = result.output.split(whereSeparator: \.isNewline).last.map(String.init),
               let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                version = nonEmpty(payload["version"] as? String)
                prefixPath = nonEmpty(payload["prefix"] as? String)
                basePrefixPath = nonEmpty(payload["base_prefix"] as? String)
                if let p = prefixPath, let bp = basePrefixPath {
                    isVenv = p != bp
                }
                if let stdlib = nonEmpty(payload["stdlib"] as? String) {
                    let candidate = URL(fileURLWithPath: stdlib, isDirectory: true).standardizedFileURL
                    if isDirectory(candidate) { stdLibURL = candidate }
                }
                if let spList = payload["site_packages"] as? [String] {
                    sitePackagesURLs = spList
                        .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
                        .filter { isDirectory($0) }
                }
            }
        }

        let virtualEnvName: String?
        if isVenv, let prefixPath {
            virtualEnvName = URL(fileURLWithPath: prefixPath).lastPathComponent
        } else if let envVenv = nonEmpty(environment["VIRTUAL_ENV"]) {
            isVenv = true
            virtualEnvName = URL(fileURLWithPath: envVenv).lastPathComponent
        } else {
            virtualEnvName = nil
        }

        let targetManifest = manifestURL
            ?? findFirstFile(named: "pyproject.toml", in: workspaceURL)
            ?? findFirstFile(named: "requirements.txt", in: workspaceURL)
            ?? findFirstFile(named: "Pipfile", in: workspaceURL)

        var dependencies: [ProjectDependencyItem] = []
        if let targetManifest,
           let content = try? String(contentsOf: targetManifest, encoding: .utf8) {
            let lowerName = targetManifest.lastPathComponent.lowercased()
            let parsed: [ProjectDependencyItem]
            if lowerName == "pyproject.toml" {
                parsed = ProjectDependencyParsers.parsePyprojectDependencies(content, manifestURL: targetManifest)
            } else if lowerName == "pipfile" {
                parsed = ProjectDependencyParsers.parsePipfileDependencies(content, manifestURL: targetManifest)
            } else if lowerName.hasPrefix("requirements") && lowerName.hasSuffix(".txt") {
                parsed = ProjectDependencyParsers.parsePythonRequirements(content, manifestURL: targetManifest)
            } else {
                // Do not feed Python source files such as `setup.py` to the requirements.txt parser.
                parsed = []
            }
            dependencies = parsed.map { item in
                let matchedDir = locatePythonPackageDirectory(named: item.name, in: sitePackagesURLs)
                return ProjectDependencyItem(
                    id: item.id,
                    name: item.name,
                    version: item.version,
                    isDirect: item.isDirect,
                    replaceTarget: item.replaceTarget,
                    sourceDirectoryURL: matchedDir,
                    manifestURL: item.manifestURL
                )
            }
        }

        return PythonProjectEnvironmentSnapshot(
            executablePath: pythonURL?.path,
            version: version,
            prefixPath: prefixPath,
            basePrefixPath: basePrefixPath,
            isVirtualEnvironment: isVenv,
            virtualEnvName: virtualEnvName,
            stdLibURL: stdLibURL,
            sitePackagesURLs: sitePackagesURLs,
            pythonPath: nonEmpty(environment["PYTHONPATH"]),
            manifestURL: targetManifest,
            dependencies: dependencies
        )
    }

    func listDirectory(at url: URL) -> [ExternalLibraryFileEntry] {
        let normalized = url.standardizedFileURL
        guard isDirectory(normalized),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: normalized,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return urls
            .compactMap { child -> ExternalLibraryFileEntry? in
                let name = child.lastPathComponent
                guard !Self.ignoredDirectoryNames.contains(name) else { return nil }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
                let isDir = values?.isDirectory == true
                return ExternalLibraryFileEntry(
                    name: name,
                    url: child.standardizedFileURL,
                    isDirectory: isDir
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .prefix(Self.maxDirectoryEntries)
            .map { $0 }
    }

    private func locatePythonPackageDirectory(named packageName: String, in sitePackages: [URL]) -> URL? {
        let normalized = packageName.replacingOccurrences(of: "-", with: "_")
        let variants = [packageName, normalized, packageName.lowercased(), normalized.lowercased()]
        for root in sitePackages {
            for variant in variants {
                let candidate = root.appendingPathComponent(variant, isDirectory: true).standardizedFileURL
                if isDirectory(candidate) { return candidate }
            }
        }
        return nil
    }

    private func findFirstFile(named fileName: String, in root: URL) -> URL? {
        let direct = root.appendingPathComponent(fileName).standardizedFileURL
        return FileManager.default.fileExists(atPath: direct.path) ? direct : nil
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
