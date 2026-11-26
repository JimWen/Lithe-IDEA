import Foundation

/// Performs a conservative, language-aware preflight before a source
/// breakpoint is sent to a debug adapter. The adapter remains authoritative;
/// this only prevents obviously non-executable gutter locations.
public enum DebugBreakpointLocationValidator {
    public static func isCandidateLine(source: String, line: Int, languageID: String) -> Bool {
        switch languageID.lowercased() {
        case "java":
            return isExecutableJavaLine(source: source, line: line)
        case "go", "rust", "rs", "node", "js", "jsx", "ts", "tsx", "mjs", "cjs":
            return isExecutableCStyleLine(source: source, line: line, languageID: languageID.lowercased())
        case "python", "py", "pyw":
            return isExecutablePythonLine(source: source, line: line)
        default:
            guard line > 0 else { return false }
            let lines = source.components(separatedBy: .newlines)
            guard line <= lines.count else { return false }
            return !lines[line - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func isExecutableCStyleLine(source: String, line: Int, languageID: String) -> Bool {
        guard line > 0 else { return false }
        let lines = source.components(separatedBy: .newlines)
        guard line <= lines.count else { return false }

        var inBlockComment = false
        for (index, rawLine) in lines.enumerated() {
            let code = codeWithoutJavaCommentsAndStrings(
                rawLine,
                inBlockComment: &inBlockComment
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard index + 1 == line else { continue }
            guard !code.isEmpty,
                  !Self.nonExecutableOnlyLines.contains(code) else { return false }
            if languageID == "go",
               (code.hasPrefix("package ") || code.hasPrefix("import ") || code == "import" || code == "import (" || code == ")") {
                return false
            }
            if (languageID == "rust" || languageID == "rs"),
               (code.hasPrefix("#[") || code.hasPrefix("#![")
                || code.hasPrefix("use ") || code.hasPrefix("pub use ")
                || code.hasPrefix("mod ") || code.hasPrefix("pub mod ")) {
                return false
            }
            return code.contains(where: { $0.isLetter || $0.isNumber || $0 == "_" })
        }
        return false
    }

    private static func isExecutablePythonLine(source: String, line: Int) -> Bool {
        guard line > 0 else { return false }
        let lines = source.components(separatedBy: .newlines)
        guard line <= lines.count else { return false }

        var tripleDelimiter: String?
        for (index, rawLine) in lines.enumerated() {
            let code = codeWithoutPythonCommentsAndStrings(
                rawLine,
                tripleDelimiter: &tripleDelimiter
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard index + 1 == line else { continue }
            guard !code.isEmpty,
                  !code.hasPrefix("@"),
                  !Self.nonExecutableOnlyLines.contains(code) else { return false }
            return code.contains(where: { $0.isLetter || $0.isNumber || $0 == "_" })
        }
        return false
    }

    private static func codeWithoutPythonCommentsAndStrings(
        _ line: String,
        tripleDelimiter: inout String?
    ) -> String {
        var result = ""
        let chars = Array(line)
        var i = 0
        var inQuote: Character?
        while i < chars.count {
            if let delim = tripleDelimiter {
                let q = delim.first!
                if chars[i] == "\\", i + 1 < chars.count {
                    i += 2
                    continue
                }
                if i + 2 < chars.count, chars[i] == q, chars[i + 1] == q, chars[i + 2] == q {
                    tripleDelimiter = nil
                    result.append(" ")
                    i += 3
                } else {
                    i += 1
                }
                continue
            }
            if let q = inQuote {
                if chars[i] == "\\", i + 1 < chars.count {
                    i += 2
                } else if chars[i] == q {
                    inQuote = nil
                    result.append(" ")
                    i += 1
                } else {
                    i += 1
                }
                continue
            }
            if chars[i] == "#" {
                break
            }
            if (chars[i] == "\"" || chars[i] == "'") {
                let q = chars[i]
                if i + 2 < chars.count, chars[i + 1] == q, chars[i + 2] == q {
                    tripleDelimiter = String(repeating: q, count: 3)
                    result.append(" ")
                    i += 3
                } else {
                    inQuote = q
                    result.append(" ")
                    i += 1
                }
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    public static func isExecutableJavaLine(source: String, line: Int) -> Bool {
        guard line > 0 else { return false }
        let lines = source.components(separatedBy: .newlines)
        guard line <= lines.count else { return false }

        var inBlockComment = false
        for (index, rawLine) in lines.enumerated() {
            let code = codeWithoutJavaCommentsAndStrings(
                rawLine,
                inBlockComment: &inBlockComment
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard index + 1 == line else { continue }
            guard !code.isEmpty,
                  !code.hasPrefix("@"),
                  !isJavaTypeDeclaration(code),
                  !Self.nonExecutableOnlyLines.contains(code) else { return false }
            return code.contains(where: { $0.isLetter || $0.isNumber || $0 == "_" })
        }
        return false
    }

    private static let nonExecutableOnlyLines: Set<String> = [
        "{", "}", "(", ")", "[", "]", ";", ",", ":"
    ]

    /// Type declarations do not represent a Java execution location. Modifiers
    /// are parsed as tokens so declarations such as `public final class` and
    /// `private static interface` are treated the same as their short forms.
    private static func isJavaTypeDeclaration(_ code: String) -> Bool {
        let tokens = code.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard !tokens.isEmpty else { return false }
        let modifiers: Set<Substring> = [
            "public", "private", "protected", "abstract", "final", "static", "sealed", "non-sealed", "strictfp"
        ]
        var index = 0
        while index < tokens.count, modifiers.contains(tokens[index]) {
            index += 1
        }
        guard index < tokens.count else { return false }
        if tokens[index] == "@interface" { return true }
        return ["class", "interface", "enum", "record"].contains(tokens[index])
    }

    private static func codeWithoutJavaCommentsAndStrings(
        _ line: String,
        inBlockComment: inout Bool
    ) -> String {
        var result = ""
        var index = line.startIndex
        var inString: Character?
        while index < line.endIndex {
            let next = line.index(after: index)
            let character = line[index]
            let following = next < line.endIndex ? line[next] : nil
            if inBlockComment {
                if character == "*", following == "/" {
                    inBlockComment = false
                    index = line.index(after: next)
                } else {
                    index = next
                }
                continue
            }
            if let quote = inString {
                if character == "\\" {
                    index = next < line.endIndex ? line.index(after: next) : next
                } else if character == quote {
                    inString = nil
                    result.append(" ")
                    index = next
                } else {
                    index = next
                }
                continue
            }
            if character == "/", following == "*" {
                inBlockComment = true
                index = line.index(after: next)
            } else if character == "/", following == "/" {
                break
            } else if character == "\"" || character == "'" {
                inString = character
                result.append(" ")
                index = next
            } else {
                result.append(character)
                index = next
            }
        }
        return result
    }
}
