import Foundation
import LitheCoreContracts

@MainActor
public final class RustExecutionCapability: NSObject,
    LanguageRunExtensionProviding,
    LanguageTestExtensionProviding,
    LanguageDebugExtensionProviding {
    public let languageID = rustLanguageID
    public let debugAdapterLaunch = LanguageDebugAdapterLaunch(
        adapterID: "lldb",
        transport: .stdio,
        executableNames: ["lldb-dap"],
        arguments: [],
        fallbacks: [
            LanguageDebugAdapterLaunchFallback(
                executableName: "xcrun",
                argumentPrefix: ["lldb-dap"]
            )
        ]
    )
    private let sessionFactory: @MainActor () -> any LanguageExecutionSession

    public init(executionSession: any LanguageExecutionSession) {
        sessionFactory = { executionSession }
    }

    init(sessionFactory: @escaping @MainActor () -> any LanguageExecutionSession) {
        self.sessionFactory = sessionFactory
    }

    public func makeExecutionSession() -> any LanguageExecutionSession {
        sessionFactory()
    }

    public func makeTestExecutionSession() -> any LanguageExecutionSession {
        sessionFactory()
    }

    public func launchPlan(
        for request: LanguageRunExtensionRequest
    ) throws -> LanguageRunExtensionPlan {
        _ = try Self.checkedRelativePath(request.relativeFilePath)
        return LanguageRunExtensionPlan(
            executable: .toolchain("project-cargo"),
            arguments: ["run"] + request.arguments,
            environment: request.environment
        )
    }

    public func discoverTests(
        for request: LanguageTestExtensionDiscoveryRequest
    ) throws -> [LanguageTestExtensionItem] {
        let paths = try request.relativeProjectFilePaths.map(Self.checkedRelativePath)
        guard Self.isCargoProject(paths) else { return [] }
        let files = paths
            .filter { Self.isTestFile($0, projectPaths: paths) }
            .sorted()
            .map { path in
                LanguageTestExtensionItem(
                    id: "rust:file:\(path)",
                    label: path,
                    kind: .file,
                    relativeFilePath: path
                )
            }
        return [LanguageTestExtensionItem(
            id: "rust:workspace",
            label: "All Rust Tests",
            kind: .workspace
        )] + files
    }

    public func testPlan(
        for request: LanguageTestExtensionRequest
    ) throws -> LanguageTestExtensionPlan {
        let projectPaths = try request.relativeProjectFilePaths.map(Self.checkedRelativePath)
        guard Self.isCargoProject(projectPaths) else {
            throw LanguageTestExtensionError.unsupportedProject(languageID: languageID)
        }
        let arguments: [String]
        let label: String
        switch request.scope {
        case .workspace:
            arguments = ["test"]
            label = "All Rust Tests"
        case .file(let relativePath):
            let path = try Self.checkedRelativePath(relativePath)
            let fileName = path.split(separator: "/").last.map(String.init) ?? path
            if let target = Self.resolveCargoTarget(for: path, projectPaths: projectPaths) {
                arguments = ["test", target.flag, target.name]
            } else {
                arguments = ["test"]
            }
            label = fileName
        case .testCase(let identifier, let relativeFilePath):
            let name = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("\n"), !name.contains("\r") else {
                throw LanguageTestExtensionError.invalidTestIdentifier
            }
            var args = ["test"]
            var qualifiedName = name
            if let relativeFilePath {
                let path = try Self.checkedRelativePath(relativeFilePath)
                if let target = Self.resolveCargoTarget(for: path, projectPaths: projectPaths) {
                    args.append(contentsOf: [target.flag, target.name])
                    if !name.contains("::"), !target.modulePrefix.isEmpty {
                        qualifiedName = "\(target.modulePrefix)::\(name)"
                    }
                } else if !name.contains("::") {
                    let modulePrefix = Self.fileModulePrefix(for: path)
                    if !modulePrefix.isEmpty {
                        qualifiedName = "\(modulePrefix)::\(name)"
                    }
                }
            }
            args.append(contentsOf: [qualifiedName, "--", "--exact", "--nocapture"])
            arguments = args
            label = qualifiedName
        }
        return LanguageTestExtensionPlan(
            label: label,
            frameworkID: "cargo",
            launchPlan: LanguageRunExtensionPlan(
                executable: .toolchain("project-cargo"),
                arguments: arguments
            )
        )
    }

    private static func checkedRelativePath(_ value: String) throws -> String {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..") else {
            throw LanguageTestExtensionError.invalidRelativePath
        }
        return path
    }

    private static func isCargoProject(_ paths: [String]) -> Bool {
        paths.contains { path in
            path.split(separator: "/").last.map(String.init)?.lowercased() == "cargo.toml"
        }
    }

    private struct ResolvedCargoTarget {
        let flag: String
        let name: String
        let modulePrefix: String
    }

    private static func resolveCargoTarget(
        for relativePath: String,
        projectPaths: [String]
    ) -> ResolvedCargoTarget? {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let last = parts.last, last.hasSuffix(".rs") else { return nil }
        let projectSet = Set(projectPaths)
        let crateRoot = owningCrateRoot(for: relativePath, projectPaths: projectPaths)
        let cratePrefixParts = crateRoot.isEmpty ? [] : crateRoot.split(separator: "/").map(String.init)
        let crateRel = Array(parts.dropFirst(cratePrefixParts.count))
        guard crateRel.count >= 2 else { return nil }

        // Integration tests live strictly under `<crateRoot>/tests/...` (never `src/tests/...`).
        if crateRel[0].lowercased() == "tests" {
            let rel = Array(crateRel.dropFirst())
            if rel.count == 1 {
                return ResolvedCargoTarget(
                    flag: "--test",
                    name: String(rel[0].dropLast(3)),
                    modulePrefix: ""
                )
            }
            let targetName = rel[0]
            if rel.count == 2 && rel[1] == "main.rs" {
                return ResolvedCargoTarget(flag: "--test", name: targetName, modulePrefix: "")
            }
            let entryPath = (cratePrefixParts + [crateRel[0], targetName, "main.rs"]).joined(separator: "/")
            if projectSet.contains(entryPath) {
                return ResolvedCargoTarget(
                    flag: "--test",
                    name: targetName,
                    modulePrefix: modulePrefix(fromRelativeComponents: Array(rel.dropFirst()))
                )
            }
            return nil
        }

        // Additional binary targets live strictly under `<crateRoot>/src/bin/...`.
        if crateRel.count >= 3,
           crateRel[0].lowercased() == "src",
           crateRel[1].lowercased() == "bin" {
            let rel = Array(crateRel.dropFirst(2))
            if rel.count == 1 {
                return ResolvedCargoTarget(
                    flag: "--bin",
                    name: String(rel[0].dropLast(3)),
                    modulePrefix: ""
                )
            }
            let targetName = rel[0]
            if rel.count == 2 && rel[1] == "main.rs" {
                return ResolvedCargoTarget(flag: "--bin", name: targetName, modulePrefix: "")
            }
            let entryPath = (cratePrefixParts + [crateRel[0], crateRel[1], targetName, "main.rs"]).joined(separator: "/")
            if projectSet.contains(entryPath) {
                return ResolvedCargoTarget(
                    flag: "--bin",
                    name: targetName,
                    modulePrefix: modulePrefix(fromRelativeComponents: Array(rel.dropFirst()))
                )
            }
            return nil
        }

        return nil
    }

    private static func owningCrateRoot(for relativePath: String, projectPaths: [String]) -> String {
        let manifestDirs: [String] = projectPaths.compactMap { candidate in
            let parts = candidate.split(separator: "/").map(String.init)
            guard parts.last?.lowercased() == "cargo.toml" else { return nil }
            return parts.dropLast().joined(separator: "/")
        }
        return manifestDirs
            .filter { dir in
                dir.isEmpty || relativePath.hasPrefix(dir + "/")
            }
            .max { $0.count < $1.count } ?? ""
    }

    private static func modulePrefix(fromRelativeComponents rel: [String]) -> String {
        guard let fileName = rel.last, fileName.hasSuffix(".rs") else { return "" }
        var modules = Array(rel.dropLast())
        let stem = String(fileName.dropLast(3))
        if stem != "mod" && stem != "lib" && stem != "main" {
            modules.append(stem)
        }
        return modules.joined(separator: "::")
    }

    private static func fileModulePrefix(for relativePath: String) -> String {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let srcIndex = parts.lastIndex(of: "src"), srcIndex + 1 < parts.count else {
            return ""
        }
        let rel = Array(parts[(srcIndex + 1)...])
        guard let fileName = rel.last, fileName.hasSuffix(".rs") else { return "" }
        if rel.first == "bin" { return "" }
        if rel.count == 1, fileName == "lib.rs" || fileName == "main.rs" { return "" }
        return modulePrefix(fromRelativeComponents: rel)
    }

    private static func isTestFile(_ path: String, projectPaths: [String]) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        let name = parts.last?.lowercased() ?? ""
        guard name.hasSuffix(".rs") else { return false }
        if name.hasSuffix("_test.rs") { return true }
        let crateRoot = owningCrateRoot(for: path, projectPaths: projectPaths)
        let prefixCount = crateRoot.isEmpty ? 0 : crateRoot.split(separator: "/").count
        let crateRel = Array(parts.dropFirst(prefixCount))
        return crateRel.count >= 2 && crateRel[0].lowercased() == "tests"
    }
}
