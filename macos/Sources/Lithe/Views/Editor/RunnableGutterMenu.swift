import SwiftUI
import LitheCoreContracts

/// Deterministic line-level runnable discovery for Go, Rust, and Python source files.
enum DocumentRunnableDiscovery {
    static func languageID(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "go": "go"
        case "rs": "rust"
        case "py": "python"
        default: nil
        }
    }

    static func discover(
        in text: String,
        url: URL,
        isLanguageEnabled: (String) -> Bool = { _ in true }
    ) -> [DocumentRunnable] {
        switch url.pathExtension.lowercased() {
        case "go":
            guard isLanguageEnabled("go") else { return [] }
            return discoverGoRunnables(in: text, url: url)
        case "rs":
            guard isLanguageEnabled("rust") else { return [] }
            return discoverRustRunnables(in: text, url: url)
        case "py":
            guard isLanguageEnabled("python") else { return [] }
            return discoverPythonRunnables(in: text, url: url)
        default:
            return []
        }
    }

    static func discoverGoRunnables(in text: String, url: URL) -> [DocumentRunnable] {
        guard url.pathExtension.lowercased() == "go" else { return [] }
        let lines = text.components(separatedBy: .newlines)
        let isTestFile = url.lastPathComponent.hasSuffix("_test.go")
        let isMainPackage = lines.contains {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed == "package main" || trimmed.hasPrefix("package main ") || trimmed.hasPrefix("package main//")
        }
        return lines.enumerated().compactMap { index, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("func ") else { return nil }
            let suffix = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            // Exclude receiver methods (`func (s *S) Foo()`).
            guard !suffix.hasPrefix("(") else { return nil }
            let name = suffix
                .components(separatedBy: CharacterSet(charactersIn: "([{ "))
                .first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !name.isEmpty else { return nil }
            let kind: DocumentRunnable.Kind?
            if name == "main" && isMainPackage && !isTestFile {
                kind = .application
            } else if isTestFile && name.hasPrefix("Test") && name != "TestMain" {
                kind = .test
            } else if isTestFile && name.hasPrefix("Benchmark") {
                kind = .benchmark
            } else if isTestFile && name.hasPrefix("Example") {
                kind = .example
            } else {
                kind = nil
            }
            guard let kind else { return nil }
            let position = LanguageServerPosition(line: index, utf16Column: 0)
            let displayName = kind == .application
                ? url.deletingLastPathComponent().lastPathComponent
                : name
            return DocumentRunnable(
                id: "go:\(kind.rawValue):\(name):\(index + 1)",
                configurationID: nil,
                displayName: displayName,
                kind: kind,
                line: index + 1,
                symbolRange: LanguageServerRange(start: position, end: position)
            )
        }
    }

    static func discoverRustRunnables(in text: String, url: URL) -> [DocumentRunnable] {
        guard url.pathExtension.lowercased() == "rs" else { return [] }
        let lines = text.components(separatedBy: .newlines)
        let fileModulePath = rustFileModulePath(for: url)
        var results: [DocumentRunnable] = []
        var pendingKind: DocumentRunnable.Kind?
        var pendingInlineModName: String?
        var braceDepth = 0
        var modStack: [(name: String, depth: Int)] = []
        var inBlockComment = false

        for (index, raw) in lines.enumerated() {
            let stripped = stripRustCommentsAndStrings(raw, inBlockComment: &inBlockComment)
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)

            // Pop closed inline `mod` scopes whenever leading closing braces close them
            // before evaluating declarations on this line.
            if trimmed.hasPrefix("}") {
                var leadingCloses = 0
                for ch in trimmed {
                    if ch == "}" { leadingCloses += 1 }
                    else if ch == " " || ch == "\t" { continue }
                    else { break }
                }
                let depthAfterLeading = max(0, braceDepth - leadingCloses)
                while let last = modStack.last, depthAfterLeading < last.depth {
                    modStack.removeLast()
                }
            }

            if !trimmed.isEmpty {
                if trimmed.hasPrefix("#[") {
                    if let attrKind = rustAttributeRunnableKind(trimmed) {
                        pendingKind = attrKind
                    }
                } else if let modName = rustInlineModuleDeclarationName(from: trimmed) {
                    pendingKind = nil
                    if trimmed.contains("{") {
                        modStack.append((name: modName, depth: braceDepth + 1))
                        pendingInlineModName = nil
                    } else if !trimmed.contains(";") {
                        pendingInlineModName = modName
                    }
                } else if let pendingMod = pendingInlineModName, trimmed.hasPrefix("{") {
                    modStack.append((name: pendingMod, depth: braceDepth + 1))
                    pendingInlineModName = nil
                } else if let fnName = rustFunctionName(from: trimmed) {
                    pendingInlineModName = nil
                    let kind: DocumentRunnable.Kind?
                    if let pendingKind {
                        kind = pendingKind
                    } else if fnName == "main" && modStack.isEmpty {
                        kind = .application
                    } else {
                        kind = nil
                    }
                    pendingKind = nil
                    if let kind {
                        let position = LanguageServerPosition(line: index, utf16Column: 0)
                        let displayName: String
                        if kind == .application {
                            let packageRoot = url.deletingLastPathComponent().deletingLastPathComponent()
                            displayName = packageRoot.lastPathComponent.isEmpty
                                ? url.deletingLastPathComponent().lastPathComponent
                                : packageRoot.lastPathComponent
                        } else {
                            let qualified = (fileModulePath + modStack.map(\.name) + [fnName]).joined(separator: "::")
                            displayName = qualified
                        }
                        results.append(DocumentRunnable(
                            id: "rust:\(kind.rawValue):\(displayName):\(index + 1)",
                            configurationID: nil,
                            displayName: displayName,
                            kind: kind,
                            line: index + 1,
                            symbolRange: LanguageServerRange(start: position, end: position)
                        ))
                    }
                } else {
                    pendingKind = nil
                    if !trimmed.hasPrefix("where") && !trimmed.hasPrefix("{") {
                        pendingInlineModName = nil
                    }
                }
            }

            for ch in stripped {
                if ch == "{" {
                    braceDepth += 1
                } else if ch == "}" {
                    braceDepth = max(0, braceDepth - 1)
                    while let last = modStack.last, braceDepth < last.depth {
                        modStack.removeLast()
                    }
                }
            }
        }
        return results
    }

    /// Computes Cargo's Rust module path prefix from a file URL (e.g. `src/math/ops.rs` -> `["math", "ops"]`,
    /// `src/math/mod.rs` -> `["math"]`, `src/lib.rs`/`src/main.rs`/`tests/foo.rs` -> `[]`).
    static func rustFileModulePath(for url: URL) -> [String] {
        let components = url.standardizedFileURL.pathComponents
        guard let srcIndex = components.lastIndex(of: "src"), srcIndex + 1 < components.count else {
            return []
        }
        let relative = Array(components[(srcIndex + 1)...])
        guard let fileName = relative.last, fileName.hasSuffix(".rs") else { return [] }
        if relative.first == "bin" {
            // `src/bin/<name>.rs` and `src/bin/<name>/main.rs` are binary crate roots (`[]`),
            // while nested files like `src/bin/<name>/helpers.rs` retain `["helpers"]`.
            guard relative.count >= 3 else { return [] }
            let underTarget = Array(relative.dropFirst(2))
            if underTarget.count == 1 && fileName == "main.rs" {
                return []
            }
            var modules = Array(underTarget.dropLast())
            let stem = String(fileName.dropLast(3))
            if stem != "mod" && stem != "lib" && stem != "main" {
                modules.append(stem)
            }
            return modules
        }
        if relative.count == 1, fileName == "lib.rs" || fileName == "main.rs" {
            return []
        }
        var modules = Array(relative.dropLast())
        let stem = String(fileName.dropLast(3))
        if stem != "mod" && stem != "lib" && stem != "main" {
            modules.append(stem)
        }
        return modules
    }

    private static func rustInlineModuleDeclarationName(from trimmed: String) -> String? {
        guard let range = trimmed.range(
            of: #"(?:^|\s)mod\s+([A-Za-z_][A-Za-z0-9_]*)\b"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let matched = String(trimmed[range])
        guard let kw = matched.range(of: "mod") else { return nil }
        let name = matched[kw.upperBound...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func stripRustCommentsAndStrings(_ line: String, inBlockComment: inout Bool) -> String {
        let chars = Array(line)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            let next: Character? = (i + 1 < chars.count) ? chars[i + 1] : nil
            if inBlockComment {
                if c == "*" && next == "/" {
                    inBlockComment = false
                    i += 2
                } else {
                    i += 1
                }
                continue
            }
            if inString {
                if c == "\\" && next != nil {
                    i += 2
                    continue
                }
                if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }
            if c == "/" && next == "/" {
                break
            }
            if c == "/" && next == "*" {
                inBlockComment = true
                i += 2
                continue
            }
            if c == "\"" {
                inString = true
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    static func discoverPythonRunnables(in text: String, url: URL) -> [DocumentRunnable] {
        guard url.pathExtension.lowercased() == "py" else { return [] }
        let lines = text.components(separatedBy: .newlines)
        var results: [DocumentRunnable] = []
        var currentTestClass: (name: String, indent: Int)?

        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            let indent = leadingWhitespaceWidth(of: raw)
            if let activeClass = currentTestClass, indent <= activeClass.indent {
                currentTestClass = nil
            }
            if indent == 0,
               (trimmed.hasPrefix("if __name__ == \"__main__\":")
                || trimmed.hasPrefix("if __name__ == '__main__':")
                || trimmed.replacingOccurrences(of: " ", with: "").hasPrefix("if__name__==\"__main__\":")
                || trimmed.replacingOccurrences(of: " ", with: "").hasPrefix("if__name__=='__main__':")) {
                let position = LanguageServerPosition(line: index, utf16Column: 0)
                results.append(DocumentRunnable(
                    id: "python:application:\(url.lastPathComponent):\(index + 1)",
                    configurationID: nil,
                    displayName: url.deletingPathExtension().lastPathComponent,
                    kind: .application,
                    line: index + 1,
                    symbolRange: LanguageServerRange(start: position, end: position)
                ))
                continue
            }
            if indent == 0, let className = pythonClassName(from: trimmed), className.hasPrefix("Test") {
                currentTestClass = (className, indent)
                continue
            }
            if let fnName = pythonFunctionName(from: trimmed), fnName.hasPrefix("test_") {
                let position = LanguageServerPosition(line: index, utf16Column: indent)
                let identifier: String
                if let activeClass = currentTestClass, indent > activeClass.indent {
                    identifier = "\(activeClass.name)::\(fnName)"
                } else if indent == 0 {
                    identifier = fnName
                } else {
                    continue
                }
                results.append(DocumentRunnable(
                    id: "python:test:\(identifier):\(index + 1)",
                    configurationID: nil,
                    displayName: identifier,
                    kind: .test,
                    line: index + 1,
                    symbolRange: LanguageServerRange(start: position, end: position)
                ))
            }
        }
        return results
    }

    private static func rustAttributeRunnableKind(_ trimmed: String) -> DocumentRunnable.Kind? {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        if compact == "#[test]"
            || compact.hasPrefix("#[tokio::test")
            || compact.hasPrefix("#[async_std::test")
            || compact.hasPrefix("#[actix_rt::test")
            || compact.hasPrefix("#[rstest") {
            return .test
        }
        if compact == "#[bench]" {
            return .benchmark
        }
        return nil
    }

    private static func rustFunctionName(from trimmed: String) -> String? {
        guard let fnRange = trimmed.range(of: #"(?:^|\s)fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:<|\()"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(trimmed[fnRange])
        guard let fnKeyword = matched.range(of: "fn") else { return nil }
        let after = matched[fnKeyword.upperBound...].trimmingCharacters(in: .whitespaces)
        let name = after.components(separatedBy: CharacterSet(charactersIn: "<( ")).first ?? ""
        return name.isEmpty ? nil : name
    }

    private static func pythonClassName(from trimmed: String) -> String? {
        guard trimmed.hasPrefix("class ") else { return nil }
        let after = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
        let name = after.components(separatedBy: CharacterSet(charactersIn: "(: ")).first ?? ""
        return name.isEmpty ? nil : name
    }

    private static func pythonFunctionName(from trimmed: String) -> String? {
        let rest: Substring
        if trimmed.hasPrefix("async def ") {
            rest = trimmed.dropFirst(10)
        } else if trimmed.hasPrefix("def ") {
            rest = trimmed.dropFirst(4)
        } else {
            return nil
        }
        let name = rest.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet(charactersIn: "( "))
            .first ?? ""
        return name.isEmpty ? nil : name
    }

    private static func leadingWhitespaceWidth(of line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 4 }
            else { break }
        }
        return count
    }
}

/// Shared menu projection for editor runnable markers. Both mouse buttons use
/// this view so the actions remain identical and revision checks stay at the
/// execution boundary.
struct RunnableGutterMenu: View {
    let runnable: DocumentRunnable
    let onRun: () -> Void
    let onDebug: () -> Void
    let onModify: () -> Void

    var body: some View {
        Group {
            Button("Run ‘\(runnable.displayName)’", action: onRun)
            Button("Debug ‘\(runnable.displayName)’", action: onDebug)
            Divider()
            Button("Modify Run Configuration…", action: onModify)
        }
        .accessibilityElement(children: .contain)
    }
}
