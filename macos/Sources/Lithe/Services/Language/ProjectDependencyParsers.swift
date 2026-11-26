import Foundation

/// Pure, deterministic manifest parsers for Go (`go.mod`), Rust (`Cargo.toml` + `Cargo.lock`),
/// and Python (`pyproject.toml` + `requirements.txt`) with zero disk or process I/O.
enum ProjectDependencyParsers {
    // MARK: - Go (`go.mod`)

    struct ParsedGoMod: Equatable, Sendable {
        struct Requirement: Equatable, Sendable {
            let modulePath: String
            let version: String
            let isIndirect: Bool
        }

        struct Replacement: Equatable, Sendable {
            let oldModule: String
            let oldVersion: String?
            let newTarget: String
            let newVersion: String?
        }

        let moduleName: String?
        let goDirective: String?
        let toolchain: String?
        let requirements: [Requirement]
        let replacements: [Replacement]
    }

    static func parseGoMod(_ text: String) -> ParsedGoMod {
        var moduleName: String?
        var goDirective: String?
        var toolchain: String?
        var requirements: [ParsedGoMod.Requirement] = []
        var replacements: [ParsedGoMod.Replacement] = []

        enum Block { case none, require, replace, other }
        var block: Block = .none

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let commentRange = line.range(of: "//")
            let codePart = commentRange.map { String(line[..<$0.lowerBound]) } ?? line
            let commentPart = commentRange.map { String(line[$0.upperBound...]) } ?? ""
            let isIndirect = commentPart.lowercased().contains("indirect")
            let trimmed = codePart.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed == ")" {
                block = .none
                continue
            }

            if block == .none {
                let tokens = splitGoModTokens(trimmed)
                guard let keyword = tokens.first else { continue }
                switch keyword {
                case "module":
                    if tokens.count >= 2 { moduleName = unquoteGoMod(tokens[1]) }
                case "go":
                    if tokens.count >= 2 { goDirective = unquoteGoMod(tokens[1]) }
                case "toolchain":
                    if tokens.count >= 2 { toolchain = unquoteGoMod(tokens[1]) }
                case "require":
                    if tokens.contains("(") {
                        block = .require
                    } else if tokens.count >= 3 {
                        requirements.append(.init(
                            modulePath: unquoteGoMod(tokens[1]),
                            version: unquoteGoMod(tokens[2]),
                            isIndirect: isIndirect
                        ))
                    }
                case "replace":
                    if tokens.contains("(") {
                        block = .replace
                    } else if let rep = parseGoModReplace(Array(tokens.dropFirst())) {
                        replacements.append(rep)
                    }
                case "exclude", "retract":
                    if tokens.contains("(") { block = .other }
                default:
                    break
                }
            } else {
                let tokens = splitGoModTokens(trimmed)
                guard !tokens.isEmpty else { continue }
                switch block {
                case .require:
                    if tokens.count >= 2 {
                        requirements.append(.init(
                            modulePath: unquoteGoMod(tokens[0]),
                            version: unquoteGoMod(tokens[1]),
                            isIndirect: isIndirect
                        ))
                    }
                case .replace:
                    if let rep = parseGoModReplace(tokens) {
                        replacements.append(rep)
                    }
                case .other, .none:
                    break
                }
            }
        }

        return ParsedGoMod(
            moduleName: moduleName,
            goDirective: goDirective,
            toolchain: toolchain,
            requirements: requirements,
            replacements: replacements
        )
    }

    /// Official Go module-cache path escaping (`golang.org/x/mod/module.EscapePath`):
    /// every uppercase ASCII letter `X` becomes `!x`.
    static func escapeGoModulePath(_ path: String) -> String {
        var result = ""
        result.reserveCapacity(path.count + 4)
        for scalar in path.unicodeScalars {
            if scalar.value >= 65 && scalar.value <= 90 {
                result.append("!")
                result.append(Character(UnicodeScalar(scalar.value + 32)!))
            } else {
                result.append(Character(scalar))
            }
        }
        return result
    }

    /// Resolves parsed `go.mod` requirements to `ProjectDependencyItem` values with
    /// optional local cache / replacement directory URLs validated via `directoryExists`.
    static func resolveGoDependencies(
        parsed: ParsedGoMod,
        manifestURL: URL?,
        goModCache: String?,
        directoryExists: (URL) -> Bool
    ) -> [ProjectDependencyItem] {
        let manifestDir = manifestURL?.deletingLastPathComponent().standardizedFileURL
        let cacheURL = goModCache
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }

        return parsed.requirements.map { req in
            let replacement = parsed.replacements.first(where: {
                $0.oldModule == req.modulePath && ($0.oldVersion == nil || $0.oldVersion == req.version)
            })
            var resolvedURL: URL?
            var replaceSummary: String?
            if let replacement {
                if let newVersion = replacement.newVersion {
                    replaceSummary = "\(replacement.newTarget) \(newVersion)"
                    if let cacheURL {
                        let candidate = cacheURL
                            .appendingPathComponent("\(escapeGoModulePath(replacement.newTarget))@\(newVersion)", isDirectory: true)
                            .standardizedFileURL
                        if directoryExists(candidate) { resolvedURL = candidate }
                    }
                } else {
                    replaceSummary = replacement.newTarget
                    let rawTarget = replacement.newTarget
                    let candidate: URL
                    if rawTarget.hasPrefix("/") {
                        candidate = URL(fileURLWithPath: rawTarget, isDirectory: true).standardizedFileURL
                    } else if let manifestDir {
                        candidate = manifestDir.appendingPathComponent(rawTarget, isDirectory: true).standardizedFileURL
                    } else {
                        candidate = URL(fileURLWithPath: rawTarget, isDirectory: true).standardizedFileURL
                    }
                    if directoryExists(candidate) { resolvedURL = candidate }
                }
            } else if let cacheURL {
                let candidate = cacheURL
                    .appendingPathComponent("\(escapeGoModulePath(req.modulePath))@\(req.version)", isDirectory: true)
                    .standardizedFileURL
                if directoryExists(candidate) { resolvedURL = candidate }
            }
            return ProjectDependencyItem(
                id: "go:\(req.modulePath)@\(req.version)",
                name: req.modulePath,
                version: req.version,
                isDirect: !req.isIndirect,
                replaceTarget: replaceSummary,
                sourceDirectoryURL: resolvedURL,
                manifestURL: manifestURL
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirect != rhs.isDirect { return lhs.isDirect }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func splitGoModTokens(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for ch in line {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "`" {
                quote = ch
                current.append(ch)
            } else if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func unquoteGoMod(_ token: String) -> String {
        if token.count >= 2,
           (token.hasPrefix("\"") && token.hasSuffix("\""))
           || (token.hasPrefix("`") && token.hasSuffix("`")) {
            return String(token.dropFirst().dropLast())
        }
        return token
    }

    private static func parseGoModReplace(_ tokens: [String]) -> ParsedGoMod.Replacement? {
        guard let arrowIndex = tokens.firstIndex(of: "=>"), arrowIndex >= 1, arrowIndex + 1 < tokens.count else {
            return nil
        }
        let left = Array(tokens[..<arrowIndex]).map(unquoteGoMod)
        let right = Array(tokens[(arrowIndex + 1)...]).map(unquoteGoMod)
        guard let oldModule = left.first, let newTarget = right.first else { return nil }
        return ParsedGoMod.Replacement(
            oldModule: oldModule,
            oldVersion: left.count >= 2 ? left[1] : nil,
            newTarget: newTarget,
            newVersion: right.count >= 2 ? right[1] : nil
        )
    }

    // MARK: - Rust (`Cargo.toml` + `Cargo.lock`)

    struct ParsedCargoManifest: Equatable, Sendable {
        struct Dependency: Equatable, Sendable {
            let name: String
            let packageName: String
            let versionRequirement: String
            let localPath: String?
            let isDevOrBuild: Bool
        }

        let crateName: String?
        let dependencies: [Dependency]
    }

    static func parseCargoToml(_ text: String) -> ParsedCargoManifest {
        var crateName: String?
        var dependencies: [ParsedCargoManifest.Dependency] = []
        var currentSection = ""

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = stripTomlComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = unquoteToml(String(line[..<eq]).trimmingCharacters(in: .whitespaces))
            let rawValue = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            if currentSection == "package", key == "name" {
                crateName = unquoteToml(rawValue)
                continue
            }

            let isNormalDepSection = currentSection == "dependencies" || currentSection == "workspace.dependencies"
            let isDevOrBuildSection = currentSection == "dev-dependencies" || currentSection == "build-dependencies"
            if isNormalDepSection || isDevOrBuildSection {
                if rawValue.hasPrefix("{") {
                    let version = extractInlineTomlField("version", from: rawValue) ?? ""
                    let path = extractInlineTomlField("path", from: rawValue)
                    let pkg = extractInlineTomlField("package", from: rawValue) ?? key
                    dependencies.append(.init(
                        name: key,
                        packageName: pkg,
                        versionRequirement: version,
                        localPath: path,
                        isDevOrBuild: isDevOrBuildSection
                    ))
                } else {
                    dependencies.append(.init(
                        name: key,
                        packageName: key,
                        versionRequirement: unquoteToml(rawValue),
                        localPath: nil,
                        isDevOrBuild: isDevOrBuildSection
                    ))
                }
            } else if currentSection.hasPrefix("dependencies.")
                        || currentSection.hasPrefix("dev-dependencies.")
                        || currentSection.hasPrefix("build-dependencies.") {
                let parts = currentSection.split(separator: ".", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let depName = unquoteToml(parts[1])
                let isDev = parts[0] != "dependencies"
                if let idx = dependencies.firstIndex(where: { $0.name == depName && $0.isDevOrBuild == isDev }) {
                    let existing = dependencies[idx]
                    dependencies[idx] = .init(
                        name: existing.name,
                        packageName: key == "package" ? unquoteToml(rawValue) : existing.packageName,
                        versionRequirement: key == "version" ? unquoteToml(rawValue) : existing.versionRequirement,
                        localPath: key == "path" ? unquoteToml(rawValue) : existing.localPath,
                        isDevOrBuild: existing.isDevOrBuild
                    )
                } else {
                    dependencies.append(.init(
                        name: depName,
                        packageName: key == "package" ? unquoteToml(rawValue) : depName,
                        versionRequirement: key == "version" ? unquoteToml(rawValue) : "",
                        localPath: key == "path" ? unquoteToml(rawValue) : nil,
                        isDevOrBuild: isDev
                    ))
                }
            }
        }

        return ParsedCargoManifest(crateName: crateName, dependencies: dependencies)
    }

    struct CargoLockPackage: Equatable, Sendable {
        let name: String
        let version: String
        let dependencies: [String]
    }

    /// Parses `Cargo.lock` into structured package records including each package's
    /// dependency references so multi-version crates resolve to the exact version used
    /// by the owning crate or compatible with the declared semver requirement.
    static func parseCargoLockPackages(_ text: String) -> [CargoLockPackage] {
        var packages: [CargoLockPackage] = []
        var inPackage = false
        var inDependenciesArray = false
        var currentName: String?
        var currentVersion: String?
        var currentDeps: [String] = []

        func flush() {
            if let name = currentName, let version = currentVersion {
                packages.append(CargoLockPackage(
                    name: name,
                    version: version,
                    dependencies: currentDeps
                ))
            }
            currentName = nil
            currentVersion = nil
            currentDeps = []
            inDependenciesArray = false
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line == "[[package]]" {
                flush()
                inPackage = true
                continue
            }
            if line.hasPrefix("[") && !inDependenciesArray {
                flush()
                inPackage = false
                continue
            }
            guard inPackage else { continue }
            if inDependenciesArray {
                currentDeps.append(contentsOf: extractQuotedStrings(in: line))
                if stripQuotedStrings(in: line).contains("]") {
                    inDependenciesArray = false
                }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if key == "name" {
                currentName = unquoteToml(rawValue)
            } else if key == "version" {
                currentVersion = unquoteToml(rawValue)
            } else if key == "dependencies", rawValue.contains("[") {
                currentDeps.append(contentsOf: extractQuotedStrings(in: rawValue))
                if !stripQuotedStrings(in: rawValue).contains("]") {
                    inDependenciesArray = true
                }
            }
        }
        flush()
        return packages
    }

    /// Backward-compatible lookup mapping package names to all locked versions.
    static func parseCargoLockVersions(_ text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for pkg in parseCargoLockPackages(text) {
            result[pkg.name, default: []].append(pkg.version)
        }
        return result
    }

    /// Resolves the exact locked version for `packageName` declared by `ownerCrateName`
    /// with optional semver `versionRequirement` (`"0.9"`, `"^1.0"`, `"=1.2.3"`, etc.).
    static func resolveCargoLockedVersion(
        packageName: String,
        versionRequirement: String,
        ownerCrateName: String?,
        lockPackages: [CargoLockPackage]
    ) -> String? {
        let candidates = lockPackages.filter { $0.name == packageName }.map(\.version)
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 {
            return candidates[0]
        }

        // 1. Prefer an explicit disambiguated dependency entry on the owning crate in Cargo.lock
        // (Cargo writes `"rand 0.9.0"` whenever multiple versions of `rand` coexist in the lockfile).
        if let ownerCrateName,
           let ownerPkg = lockPackages.first(where: { $0.name == ownerCrateName }) {
            for depSpec in ownerPkg.dependencies {
                let parts = depSpec.split(separator: " ").map(String.init)
                if parts.count >= 2, parts[0] == packageName, candidates.contains(parts[1]) {
                    return parts[1]
                }
            }
        }

        // 2. Match against the declared Cargo semver requirement.
        let req = versionRequirement.trimmingCharacters(in: .whitespacesAndNewlines)
        if !req.isEmpty, req != "*" {
            if let matched = candidates.first(where: { cargoVersion($0, satisfies: req) }) {
                return matched
            }
        }

        return candidates.first
    }

    static func cargoVersion(_ locked: String, satisfies requirement: String) -> Bool {
        let clauses = requirement.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !clauses.isEmpty else { return true }
        let lockedParts = parseSemverTuple(locked)
        for clause in clauses {
            if clause == "*" { continue }
            if clause.hasPrefix("=") {
                let target = String(clause.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !locked.hasPrefix(target) { return false }
            } else if clause.hasPrefix(">=") {
                let target = parseSemverTuple(String(clause.dropFirst(2)))
                if compareSemver(lockedParts, target) < 0 { return false }
            } else if clause.hasPrefix("<=") {
                let target = parseSemverTuple(String(clause.dropFirst(2)))
                if compareSemver(lockedParts, target) > 0 { return false }
            } else if clause.hasPrefix(">") {
                let target = parseSemverTuple(String(clause.dropFirst(1)))
                if compareSemver(lockedParts, target) <= 0 { return false }
            } else if clause.hasPrefix("<") {
                let target = parseSemverTuple(String(clause.dropFirst(1)))
                if compareSemver(lockedParts, target) >= 0 { return false }
            } else {
                // Caret (`^` or bare Cargo requirement) or tilde (`~`) compatibility.
                let isTilde = clause.hasPrefix("~")
                let bare = (clause.hasPrefix("^") || isTilde)
                    ? String(clause.dropFirst()).trimmingCharacters(in: .whitespaces)
                    : clause
                let parts = bare.split(separator: ".").compactMap { Int($0.prefix(while: \.isNumber)) }
                guard let reqMajor = parts.first else { continue }
                let reqMinor = parts.count > 1 ? parts[1] : 0
                let reqPatch = parts.count > 2 ? parts[2] : 0
                if compareSemver(lockedParts, (reqMajor, reqMinor, reqPatch)) < 0 { return false }
                if isTilde {
                    if lockedParts.0 != reqMajor { return false }
                    if parts.count >= 2 && lockedParts.1 != reqMinor { return false }
                } else if reqMajor > 0 {
                    if lockedParts.0 != reqMajor { return false }
                } else if parts.count >= 2 && reqMinor > 0 {
                    if lockedParts.0 != 0 || lockedParts.1 != reqMinor { return false }
                } else if parts.count >= 3 {
                    if lockedParts != (0, 0, reqPatch) { return false }
                } else if parts.count == 2 {
                    if lockedParts.0 != 0 || lockedParts.1 != 0 { return false }
                } else {
                    if lockedParts.0 != 0 { return false }
                }
            }
        }
        return true
    }

    private static func parseSemverTuple(_ raw: String) -> (Int, Int, Int) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let core = trimmed.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? trimmed
        let nums = core.split(separator: ".").compactMap { Int($0.prefix(while: \.isNumber)) }
        return (
            nums.count > 0 ? nums[0] : 0,
            nums.count > 1 ? nums[1] : 0,
            nums.count > 2 ? nums[2] : 0
        )
    }

    private static func compareSemver(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        if a.0 != b.0 { return a.0 < b.0 ? -1 : 1 }
        if a.1 != b.1 { return a.1 < b.1 ? -1 : 1 }
        if a.2 != b.2 { return a.2 < b.2 ? -1 : 1 }
        return 0
    }

    // MARK: - Python (`pyproject.toml` + `requirements.txt`)

    static func parsePythonRequirements(_ text: String, manifestURL: URL?) -> [ProjectDependencyItem] {
        var items: [ProjectDependencyItem] = []
        var seen = Set<String>()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let withoutComment = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init) ?? ""
            let trimmed = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { continue }
            if let parsed = splitPythonRequirementSpec(trimmed), seen.insert(parsed.name.lowercased()).inserted {
                items.append(ProjectDependencyItem(
                    id: "py:\(parsed.name.lowercased())",
                    name: parsed.name,
                    version: parsed.version,
                    isDirect: true,
                    replaceTarget: nil,
                    sourceDirectoryURL: nil,
                    manifestURL: manifestURL
                ))
            }
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func parsePyprojectDependencies(_ text: String, manifestURL: URL?) -> [ProjectDependencyItem] {
        var items: [ProjectDependencyItem] = []
        var seen = Set<String>()
        var inDependenciesArray = false
        var currentSection = ""

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = stripTomlComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                inDependenciesArray = false
                continue
            }
            if currentSection == "project", line.hasPrefix("dependencies"), stripQuotedStrings(in: line).contains("[") {
                inDependenciesArray = true
                for quoted in extractQuotedStrings(in: line) {
                    if let parsed = splitPythonRequirementSpec(quoted), seen.insert(parsed.name.lowercased()).inserted {
                        items.append(ProjectDependencyItem(
                            id: "py:\(parsed.name.lowercased())",
                            name: parsed.name,
                            version: parsed.version,
                            isDirect: true,
                            replaceTarget: nil,
                            sourceDirectoryURL: nil,
                            manifestURL: manifestURL
                        ))
                    }
                }
                if stripQuotedStrings(in: line).contains("]") { inDependenciesArray = false }
                continue
            }
            if inDependenciesArray {
                for quoted in extractQuotedStrings(in: line) {
                    if let parsed = splitPythonRequirementSpec(quoted), seen.insert(parsed.name.lowercased()).inserted {
                        items.append(ProjectDependencyItem(
                            id: "py:\(parsed.name.lowercased())",
                            name: parsed.name,
                            version: parsed.version,
                            isDirect: true,
                            replaceTarget: nil,
                            sourceDirectoryURL: nil,
                            manifestURL: manifestURL
                        ))
                    }
                }
                if stripQuotedStrings(in: line).contains("]") { inDependenciesArray = false }
                continue
            }
            if currentSection == "tool.poetry.dependencies", let eq = line.firstIndex(of: "=") {
                let name = unquoteToml(String(line[..<eq]).trimmingCharacters(in: .whitespaces))
                guard name.lowercased() != "python", !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
                let rawValue = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                let version = rawValue.hasPrefix("{")
                    ? (extractInlineTomlField("version", from: rawValue) ?? "")
                    : unquoteToml(rawValue)
                items.append(ProjectDependencyItem(
                    id: "py:\(name.lowercased())",
                    name: name,
                    version: version,
                    isDirect: true,
                    replaceTarget: nil,
                    sourceDirectoryURL: nil,
                    manifestURL: manifestURL
                ))
            }
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func parsePipfileDependencies(_ text: String, manifestURL: URL?) -> [ProjectDependencyItem] {
        var items: [ProjectDependencyItem] = []
        var seen = Set<String>()
        var currentSection = ""

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = stripTomlComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard currentSection == "packages" || currentSection == "dev-packages",
                  let eq = line.firstIndex(of: "=") else { continue }
            let name = unquoteToml(String(line[..<eq]).trimmingCharacters(in: .whitespaces))
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            let rawValue = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            let version = rawValue.hasPrefix("{")
                ? (extractInlineTomlField("version", from: rawValue) ?? "")
                : unquoteToml(rawValue)
            items.append(ProjectDependencyItem(
                id: "py:\(name.lowercased())",
                name: name,
                version: version == "*" ? "" : version,
                isDirect: currentSection == "packages",
                replaceTarget: nil,
                sourceDirectoryURL: nil,
                manifestURL: manifestURL
            ))
        }
        return items.sorted { lhs, rhs in
            if lhs.isDirect != rhs.isDirect { return lhs.isDirect }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func stripQuotedStrings(in line: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for ch in line {
            if escaped {
                escaped = false
                continue
            }
            if let q = quote {
                if ch == "\\" && q == "\"" { escaped = true }
                else if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else {
                result.append(ch)
            }
        }
        return result
    }

    private static func splitPythonRequirementSpec(_ spec: String) -> (name: String, version: String)? {
        let cleaned = spec.split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleaned.isEmpty else { return nil }
        let separators = CharacterSet(charactersIn: "=!<>~ ")
        let namePart: String
        let versionPart: String
        if let idx = cleaned.rangeOfCharacter(from: separators)?.lowerBound {
            namePart = String(cleaned[..<idx]).trimmingCharacters(in: .whitespaces)
            versionPart = String(cleaned[idx...]).trimmingCharacters(in: .whitespaces)
        } else {
            namePart = cleaned
            versionPart = ""
        }
        let baseName = namePart.split(separator: "[", maxSplits: 1).first.map(String.init) ?? namePart
        guard !baseName.isEmpty else { return nil }
        return (baseName, versionPart)
    }

    private static func stripTomlComment(_ line: String) -> String {
        var inDouble = false
        var inSingle = false
        var escaped = false
        var output = ""
        for ch in line {
            if escaped {
                output.append(ch)
                escaped = false
                continue
            }
            if inDouble {
                if ch == "\\" { escaped = true }
                else if ch == "\"" { inDouble = false }
                output.append(ch)
                continue
            }
            if inSingle {
                if ch == "'" { inSingle = false }
                output.append(ch)
                continue
            }
            if ch == "\"" { inDouble = true; output.append(ch); continue }
            if ch == "'" { inSingle = true; output.append(ch); continue }
            if ch == "#" { break }
            output.append(ch)
        }
        return output
    }

    private static func unquoteToml(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2,
           (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
           || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static func extractInlineTomlField(_ field: String, from inlineTable: String) -> String? {
        guard let range = inlineTable.range(
            of: #"(?:^|[\{\s,])\#(field)\s*=\s*(?:"([^"]*)"|'([^']*)')"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let matched = String(inlineTable[range])
        guard let eq = matched.firstIndex(of: "=") else { return nil }
        return unquoteToml(String(matched[matched.index(after: eq)...]))
    }

    private static func extractQuotedStrings(in line: String) -> [String] {
        var results: [String] = []
        var quote: Character?
        var current = ""
        for ch in line {
            if let q = quote {
                if ch == q {
                    results.append(current)
                    current = ""
                    quote = nil
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                current = ""
            }
        }
        return results
    }
}
