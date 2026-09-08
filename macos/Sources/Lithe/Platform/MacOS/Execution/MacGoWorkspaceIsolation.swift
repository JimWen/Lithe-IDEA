import Foundation
import LitheCoreContracts

/// A byte-faithful isolated copy of the user's `go.work`.
///
/// A workspace-mode `go list -e -json ./...` writes `go.work.sum` next to the
/// go.work it resolves, so the copy lives in a host-owned temporary directory
/// instead of the user's workspace (B7a2c3). `use` paths — and relative local
/// `replace` targets, which Go resolves against the go.work directory — are
/// rewritten to symlink-resolved absolute paths so relocation cannot change
/// dependency resolution. Every other byte, including `toolchain`, `godebug`,
/// comments, separators, unknown directives and the original line endings, is
/// copied through. Rebuilding via `go work edit -json` would drop `toolchain`
/// and `godebug` and is never used; a symlinked workspace layout is rejected
/// by Go.
struct MacGoWorkspaceIsolation: Sendable {
    /// Host-owned directory holding the isolated copy and its `go.work.sum`.
    let directoryURL: URL
    /// The isolated go.work file to hand to `GOWORK`.
    let goWorkURL: URL

    /// The resolved module directories the source go.work's `use` directives
    /// name, in file order. The preparer freezes these manifests before any
    /// capture runs; the work-edit round must agree with this list.
    static func useDirectories(sourceGoWorkURL: URL) throws -> [URL] {
        let original = try Data(contentsOf: sourceGoWorkURL)
        guard let text = String(data: original, encoding: .utf8) else {
            throw ProjectMetadataFailure.invalidInput(message: "go.work is not valid UTF-8.")
        }
        let workspaceRoot = sourceGoWorkURL.deletingLastPathComponent()
        var directories: [URL] = []
        var seen: Set<String> = []
        for scanned in scannedLines(of: text) {
            guard scanned.kind == .use else { continue }
            for token in scanned.tokens {
                let directory = resolveUsePath(token.path, workspaceRoot: workspaceRoot)
                if seen.insert(directory.path).inserted { directories.append(directory) }
            }
        }
        return directories
    }

    /// Copies `sourceGoWorkURL` with only `use` paths and relative local
    /// `replace` targets rewritten, into a fresh temporary directory outside
    /// `workspaceURL`.
    static func create(workspaceURL: URL, sourceGoWorkURL: URL) throws -> MacGoWorkspaceIsolation {
        // Read and validate the source before touching the filesystem so a
        // bad source cannot leave a directory behind.
        let original = try Data(contentsOf: sourceGoWorkURL)
        guard let text = String(data: original, encoding: .utf8) else {
            throw ProjectMetadataFailure.invalidInput(message: "go.work is not valid UTF-8.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-go-workspace-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ProjectMetadataFailure.invalidInput(
                message: "Could not create the isolated Go workspace directory: \(error.localizedDescription)"
            )
        }
        // The isolation target must never sit inside the tree it isolates; the
        // real location is only known for certain after creation resolves
        // symlinks in the created path.
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedWorkspace = workspaceURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedDirectory.path != resolvedWorkspace.path,
              !resolvedDirectory.path.hasPrefix(resolvedWorkspace.path + "/") else {
            try? FileManager.default.removeItem(at: directory)
            throw ProjectMetadataFailure.invalidInput(
                message: "The Go workspace isolation directory must live outside the workspace."
            )
        }

        do {
            let rewritten = rewrite(text, workspaceRoot: sourceGoWorkURL.deletingLastPathComponent())
            try rewritten.write(
                to: resolvedDirectory.appendingPathComponent("go.work"), atomically: true, encoding: .utf8
            )
        } catch {
            var message = "Could not write the isolated Go workspace copy: \(error.localizedDescription)"
            do { try FileManager.default.removeItem(at: directory) } catch {
                message += " The partial copy at \(directory.path) could not be removed either."
            }
            throw ProjectMetadataFailure.invalidInput(message: message)
        }

        return MacGoWorkspaceIsolation(
            directoryURL: resolvedDirectory,
            goWorkURL: resolvedDirectory.appendingPathComponent("go.work")
        )
    }

    /// Deletes the isolated directory including any `go.work.sum` inside it.
    /// Returns `nil` when the directory is gone, otherwise a user-visible
    /// diagnostic: a failed cleanup is never silently discarded, and only a
    /// confirmed absence counts as success.
    @discardableResult
    func cleanup() -> String? {
        do {
            try FileManager.default.removeItem(at: directoryURL)
            return nil
        } catch {
            let native = error as NSError
            if native.domain == NSCocoaErrorDomain,
               native.code == NSFileNoSuchFileError || native.code == NSFileReadNoSuchFileError {
                return nil
            }
            return "The temporary Go workspace copy at \(directoryURL.path) could not be deleted"
                + " (\(error.localizedDescription))."
        }
    }

    // MARK: - Directive scanning

    private enum DirectiveKind {
        case use
        case replace
        /// Any line that carries no relocated path.
        case plain
    }

    /// One path token: the decoded path plus the exact range it occupies in
    /// its line, so rewriting can replace it in place.
    private struct ScannedToken {
        let path: String
        let range: Range<String.Index>
    }

    private struct ScannedLine {
        let kind: DirectiveKind
        let tokens: [ScannedToken]
        let line: String
        let terminator: String
    }

    /// Classifies every line of the file. `use` and `replace` directives carry
    /// the path tokens that must follow a relocation; CRLF terminators stay
    /// attached to their lines and are reproduced exactly.
    private static func scannedLines(of text: String) -> [ScannedLine] {
        var scanned: [ScannedLine] = []
        var inUseBlock = false
        var inReplaceBlock = false
        for (line, terminator) in terminatedLines(of: text) {
            // Newlines are included so a CRLF line's trailing `\r` cannot
            // masquerade as part of the last token.
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let useBody = trimmed.dropFirst("use".count).trimmingCharacters(in: .whitespaces)
            var kind = DirectiveKind.plain
            var tokens: [ScannedToken] = []

            if trimmed.hasPrefix("use"), useBody.hasPrefix("(") {
                inUseBlock = true
            } else if inUseBlock, trimmed.hasPrefix(")") {
                inUseBlock = false
            } else if trimmed.hasPrefix("replace"),
                      trimmed.dropFirst("replace".count).trimmingCharacters(in: .whitespaces).hasPrefix("(") {
                inReplaceBlock = true
            } else if inReplaceBlock, trimmed.hasPrefix(")") {
                inReplaceBlock = false
            } else if inUseBlock {
                // Inside a use block every non-comment token is a path; `use .`
                // and bare directory names are ordinary workspaces.
                if let paths = pathTokens(afterKeyword: nil, line: line) {
                    kind = .use
                    tokens = paths
                }
            } else if trimmed.hasPrefix("use"), isPathForm(useBody) {
                if let paths = pathTokens(afterKeyword: "use", line: line) {
                    kind = .use
                    tokens = paths
                }
            } else if inReplaceBlock || trimmed.hasPrefix("replace") {
                // `replace <module> => <path>`: only a path-shaped local target
                // follows relocation; module or module@version targets do not.
                if let arrow = line.range(of: "=>") {
                    // Keep the raw target text so the token's offset and
                    // length are measured against the original line, the
                    // space after the arrow included.
                    let rawTarget = String(line[arrow.upperBound...])
                    let leading = rawTarget.prefix { $0.isWhitespace }.count
                    let targetText = String(rawTarget.dropFirst(leading))
                    if let paths = pathTokens(afterKeyword: nil, line: targetText),
                       let first = paths.first, isPathForm(first.path) {
                        kind = .replace
                        let start = line.index(arrow.upperBound, offsetBy: leading)
                        let end = line.index(start, offsetBy: targetText.distance(
                            from: first.range.lowerBound, to: first.range.upperBound
                        ))
                        tokens = [ScannedToken(path: first.path, range: start..<end)]
                    }
                }
            }
            scanned.append(ScannedLine(kind: kind, tokens: tokens, line: line, terminator: terminator))
        }
        return scanned
    }

    /// Splits one line into path tokens separated by whitespace. A `//` that
    /// starts a token begins a comment, matching the modfile scanner, and the
    /// comment is not part of any token.
    private static func pathTokens(afterKeyword keyword: String?, line: String) -> [ScannedToken]? {
        var rest = line[...]
        if let keyword {
            guard rest.hasPrefix(keyword) else { return nil }
            rest = rest.dropFirst(keyword.count)
        }
        var tokens: [ScannedToken] = []
        while !rest.isEmpty {
            // Copy the whitespace gap before the next token.
            let gapEnd = rest.firstIndex(where: { !$0.isWhitespace }) ?? rest.endIndex
            rest = rest[gapEnd...]
            if rest.isEmpty || rest.hasPrefix("//") { break }
            let token: Substring
            if rest.hasPrefix("\"") {
                guard let close = closingQuote(in: rest) else { return nil }
                token = rest[...close]
            } else {
                let end = rest.firstIndex(where: { $0.isWhitespace }) ?? rest.endIndex
                token = rest[..<end]
            }
            tokens.append(ScannedToken(path: unquote(token), range: token.startIndex..<token.endIndex))
            rest = rest[token.endIndex...]
        }
        return tokens
    }

    private static func closingQuote(in text: Substring) -> Substring.Index? {
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            switch text[index] {
            case "\\": index = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
            case "\"": return index
            default: index = text.index(after: index)
            }
        }
        return nil
    }

    /// Decodes the quoted form into the raw path.
    private static func unquote(_ token: Substring) -> String {
        guard token.hasPrefix("\""), token.hasSuffix("\""), token.count >= 2 else { return String(token) }
        let inner = token.dropFirst().dropLast()
        var decoded = ""
        var index = inner.startIndex
        while index < inner.endIndex {
            if inner[index] == "\\", index != inner.index(before: inner.endIndex) {
                index = inner.index(after: index)
                decoded.append(inner[index])
            } else {
                decoded.append(inner[index])
            }
            index = inner.index(after: index)
        }
        return decoded
    }

    /// Re-encodes a resolved path as a go.work token, quoting whenever the
    /// path carries whitespace or quotes so the rewritten line stays valid.
    private static func quoteIfNeeded(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let needsQuotes = escaped != path || path.contains(where: { $0.isWhitespace })
        return needsQuotes ? "\"" + escaped + "\"" : path
    }

    private static func isPathForm(_ token: String) -> Bool {
        token.hasPrefix("./") || token.hasPrefix("../")
            || token.hasPrefix("/") || token.hasPrefix("\"") || token == "."
    }

    /// Resolves one `use` path against the go.work directory the same way the
    /// capture working directory resolves, so Go sees one consistent prefix.
    private static func resolveUsePath(_ token: String, workspaceRoot: URL) -> URL {
        let base = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        let candidate = URL(fileURLWithPath: token, relativeTo: base)
        return candidate.resolvingSymlinksInPath().standardizedFileURL
    }

    // MARK: - Rewriting

    /// Rewrites every relocated path, preserving all separators, comments and
    /// line endings byte for byte. Ranges are applied from the line's end
    /// backwards so earlier indices stay valid while replacing.
    private static func rewrite(_ text: String, workspaceRoot: URL) -> String {
        var output: [String] = []
        for scanned in scannedLines(of: text) {
            var line = scanned.line
            for token in scanned.tokens.reversed() {
                let replacement: String?
                switch scanned.kind {
                case .use:
                    replacement = quoteIfNeeded(
                        resolveUsePath(token.path, workspaceRoot: workspaceRoot).path
                    )
                case .replace:
                    // Relative local targets must follow the relocation or Go
                    // resolves them against the temporary directory. Absolute
                    // and version-form targets are already location-proof.
                    let followsRelocation = token.path.hasPrefix("./") || token.path.hasPrefix("../")
                        || token.path == "." || token.path == ".."
                    replacement = followsRelocation
                        ? quoteIfNeeded(resolveUsePath(token.path, workspaceRoot: workspaceRoot).path)
                        : nil
                case .plain:
                    replacement = nil
                }
                guard let replacement else { continue }
                line.replaceSubrange(token.range, with: replacement)
            }
            output.append(line + scanned.terminator)
        }
        return output.joined()
    }
}

/// Splits into line-plus-terminator pairs on the `\n` scalar so CRLF files
/// keep one `\r` attached to each line and every original terminator is
/// reproduced exactly, including a missing final newline.
private func terminatedLines(of text: String) -> [(line: String, terminator: String)] {
    var pairs: [(String, String)] = []
    var current = ""
    var iterator = text.unicodeScalars.makeIterator()
    while let scalar = iterator.next() {
        if scalar == "\n" {
            pairs.append((current, "\n"))
            current = ""
        } else {
            current.unicodeScalars.append(scalar)
        }
    }
    if !current.isEmpty { pairs.append((current, "")) }
    return pairs
}
