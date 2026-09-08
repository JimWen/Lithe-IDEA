import Foundation

/// A byte-faithful isolated copy of the user's `go.work`.
///
/// A workspace-mode `go list -e -json ./...` writes `go.work.sum` next to the
/// go.work it resolves, so the copy lives in a host-owned temporary directory
/// instead of the user's workspace (B7a2c3). Only `use` paths are rewritten —
/// to symlink-resolved absolute paths that match how capture working
/// directories resolve — and every other byte, including `toolchain`,
/// `godebug`, `replace`, comments, separators and unknown directives, is
/// copied through. Rebuilding via `go work edit -json` would drop `toolchain`
/// and `godebug` and is never used; a symlinked workspace layout is rejected
/// by Go.
struct MacGoWorkspaceIsolation: Sendable {
    /// Host-owned directory holding the isolated copy and its `go.work.sum`.
    let directoryURL: URL
    /// The isolated go.work file to hand to `GOWORK`.
    let goWorkURL: URL

    /// Copies `sourceGoWorkURL` byte for byte with only the `use` paths
    /// rewritten, into a fresh temporary directory outside `workspaceURL`.
    static func create(workspaceURL: URL, sourceGoWorkURL: URL) throws -> MacGoWorkspaceIsolation {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-go-workspace-\(UUID().uuidString)", isDirectory: true)
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedWorkspace = workspaceURL.resolvingSymlinksInPath().standardizedFileURL
        // The isolation target must never sit inside the tree it isolates, or a
        // workspace write could sneak back into the user's files.
        guard resolvedDirectory.path != resolvedWorkspace.path,
              !resolvedDirectory.path.hasPrefix(resolvedWorkspace.path + "/") else {
            throw ProjectMetadataFailure.invalidInput(
                message: "The Go workspace isolation directory must live outside the workspace."
            )
        }
        try FileManager.default.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)

        let original = try Data(contentsOf: sourceGoWorkURL)
        guard let text = String(data: original, encoding: .utf8) else {
            try? FileManager.default.removeItem(at: resolvedDirectory)
            throw ProjectMetadataFailure.invalidInput(message: "go.work is not valid UTF-8.")
        }
        let rewritten = rewriteUsePaths(text, workspaceRoot: sourceGoWorkURL.deletingLastPathComponent())
        try rewritten.write(to: resolvedDirectory.appendingPathComponent("go.work"), atomically: true, encoding: .utf8)

        return MacGoWorkspaceIsolation(
            directoryURL: resolvedDirectory,
            goWorkURL: resolvedDirectory.appendingPathComponent("go.work")
        )
    }

    /// Deletes the isolated directory including any `go.work.sum` inside it.
    /// Returns `nil` when the directory is gone, otherwise a user-visible
    /// diagnostic: a failed cleanup is never silently discarded.
    @discardableResult
    func cleanup() -> String? {
        do {
            try FileManager.default.removeItem(at: directoryURL)
            return nil
        } catch {
            // A concurrent cleanup already won; the directory is gone either way.
            if (try? FileManager.default.attributesOfItem(atPath: directoryURL.path)) == nil {
                return nil
            }
            return "The temporary Go workspace copy at \(directoryURL.path) could not be deleted"
                + " (\(error.localizedDescription))."
        }
    }

    /// Rewrites only `use`-directive paths. Block form rewrites the path lines
    /// between `use (` and `)`; single-line `use ./a ./b` form rewrites its
    /// path tokens. Everything else passes through untouched.
    private static func rewriteUsePaths(_ text: String, workspaceRoot: URL) -> String {
        var output: [String] = []
        var inUseBlock = false
        for (line, terminator) in terminatedLines(of: text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let body = trimmed.dropFirst("use".count).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("use"), body.hasPrefix("(") {
                inUseBlock = true
                output.append(line + terminator)
            } else if inUseBlock, trimmed.hasPrefix(")") {
                inUseBlock = false
                output.append(line + terminator)
            } else if inUseBlock, isUsePathLine(trimmed) {
                output.append(rewrittenPathLine(String(line), workspaceRoot: workspaceRoot) + terminator)
            } else if trimmed.hasPrefix("use"), isUsePathLine(body) {
                output.append(rewrittenUseDirective(String(line), workspaceRoot: workspaceRoot) + terminator)
            } else {
                output.append(line + terminator)
            }
        }
        return output.joined()
    }

    /// A path entry inside the use block: bare, quoted, absolute, possibly with
    /// a trailing comment — but never a comment or blank line.
    private static func isUsePathLine<T: StringProtocol>(_ trimmed: T) -> Bool {
        guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { return false }
        return trimmed.hasPrefix("./") || trimmed.hasPrefix("../")
            || trimmed.hasPrefix("/") || trimmed.hasPrefix("\"")
    }

    /// Preserves the line's leading whitespace and everything after the path
    /// token; only the path text itself is replaced.
    private static func rewrittenPathLine(_ line: String, workspaceRoot: URL) -> String {
        let leading = String(line.prefix { $0.isWhitespace })
        let tail = line.dropFirst(leading.count)
        guard let (token, remainder) = firstToken(of: tail) else { return line }
        let resolved = absoluteUsePath(token, workspaceRoot: workspaceRoot)
        return leading + resolved + remainder
    }

    /// Rewrites every path token of a single-line `use` directive, keeping the
    /// whitespace gaps, quoting and any trailing comment exactly as they were.
    private static func rewrittenUseDirective(_ line: String, workspaceRoot: URL) -> String {
        let leading = String(line.prefix { $0.isWhitespace })
        var rest = line.dropFirst(leading.count).dropFirst("use".count)
        var rebuilt = leading + "use"
        while !rest.isEmpty {
            let gapEnd = rest.firstIndex(where: { !$0.isWhitespace }) ?? rest.endIndex
            rebuilt += String(rest[..<gapEnd])
            rest = rest[gapEnd...]
            if rest.isEmpty || rest.hasPrefix("//") {
                rebuilt += String(rest)
                break
            }
            guard let (token, remainder) = firstToken(of: rest) else {
                rebuilt += String(rest)
                break
            }
            rebuilt += absoluteUsePath(token, workspaceRoot: workspaceRoot)
            rest = remainder[...]
        }
        return rebuilt
    }

    /// Takes one path token — quoted or whitespace-delimited bare — and returns
    /// it with the rest of the line, comments included.
    private static func firstToken(of text: Substring) -> (token: String, remainder: String)? {
        if text.hasPrefix("\"") {
            guard let close = text.dropFirst().firstIndex(of: "\"") else { return nil }
            return (String(text[...close]), String(text[text.index(after: close)...]))
        }
        let end = text.firstIndex(where: \.isWhitespace) ?? text.endIndex
        return (String(text[..<end]), String(text[end...]))
    }

    /// Resolves one `use` path against the go.work directory the same way the
    /// capture working directory resolves, so Go sees one consistent prefix.
    private static func absoluteUsePath(_ token: String, workspaceRoot: URL) -> String {
        let quoted = token.hasPrefix("\"") && token.hasSuffix("\"") && token.count >= 2
        let unquoted = quoted ? String(token.dropFirst().dropLast()) : token
        let base = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        let candidate = URL(fileURLWithPath: unquoted, relativeTo: base)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return quoted ? "\"" + resolved + "\"" : resolved
    }
}

/// Splits into line-plus-terminator pairs so rewritten output keeps every
/// original line ending, including a missing final newline.
private func terminatedLines(of text: String) -> [(line: Substring, terminator: String)] {
    var pairs: [(Substring, String)] = []
    var rest = text[...]
    while let index = rest.firstIndex(of: "\n") {
        pairs.append((rest[..<index], "\n"))
        rest = rest[rest.index(after: index)...]
    }
    if !rest.isEmpty { pairs.append((rest, "")) }
    return pairs
}
