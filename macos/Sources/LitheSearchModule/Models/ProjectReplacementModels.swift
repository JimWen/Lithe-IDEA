import Foundation

public struct ProjectReplacementMatch: Identifiable, Hashable, Sendable {
    public let line: Int
    public let before: String
    public let after: String
    public let occurrenceCount: Int

    public init(line: Int, before: String, after: String, occurrenceCount: Int) {
        self.line = line
        self.before = before
        self.after = after
        self.occurrenceCount = occurrenceCount
    }

    public var id: String { "\(line):\(before):\(after)" }
}

public struct ProjectReplacementFile: Identifiable, Hashable, Sendable {
    public let url: URL
    public let relativePath: String
    public let matches: [ProjectReplacementMatch]
    public let replacementText: String?
    public let sourceText: String?
    public let edits: [ProjectReplacementEdit]

    public init(
        url: URL,
        relativePath: String,
        matches: [ProjectReplacementMatch],
        replacementText: String? = nil,
        sourceText: String? = nil,
        edits: [ProjectReplacementEdit] = []
    ) {
        self.url = url
        self.relativePath = relativePath
        self.matches = matches
        self.replacementText = replacementText
        self.sourceText = sourceText
        self.edits = edits
    }

    public var id: String { url.path }
    public var matchCount: Int { matches.reduce(0) { $0 + $1.occurrenceCount } }
}

public extension ProjectReplacementFile {
    /// Rebuild from the original snapshot once. Validate even excluded edits so
    /// an invalid engine response can never become an apparently safe subset.
    func selectedReplacement(excluding excludedIDs: Set<String>) -> Result<String, ProjectSearchFailure> {
        func invalid(_ message: String) -> Result<String, ProjectSearchFailure> {
            .failure(ProjectSearchFailure(code: "invalid_preview", message: message))
        }
        guard let sourceText else { return invalid("Preview again before applying these changes.") }
        let source = Array(sourceText.utf16)
        var cursor = 0
        var previousStart: Int?
        var ids = Set<String>()
        var output = [UInt16]()
        let outputLimit = 16 * 1024 * 1024
        for edit in edits {
            let (end, overflow) = edit.utf16Start.addingReportingOverflow(edit.utf16Length)
            guard !overflow, edit.utf16Start >= cursor, edit.utf16Length >= 0,
                  end <= source.count, previousStart != edit.utf16Start,
                  ids.insert(edit.id).inserted else {
                return invalid("The preview contains overlapping or invalid match ranges.")
            }
            for offset in [edit.utf16Start, end] where offset > 0 && offset < source.count {
                guard !(0xD800...0xDBFF).contains(source[offset - 1])
                        || !(0xDC00...0xDFFF).contains(source[offset]) else {
                    return invalid("A preview match splits a Unicode character.")
                }
            }
            output.append(contentsOf: source[cursor..<edit.utf16Start])
            if excludedIDs.contains(edit.id) {
                output.append(contentsOf: source[edit.utf16Start..<end])
            } else {
                output.append(contentsOf: edit.newText.utf16)
            }
            guard output.count <= outputLimit else { return invalid("Narrow the selected replacement output.") }
            cursor = end
            previousStart = edit.utf16Start
        }
        output.append(contentsOf: source[cursor...])
        guard output.count <= outputLimit else { return invalid("Narrow the selected replacement output.") }
        let result = String(decoding: output, as: UTF16.self)
        guard result.utf8.count <= outputLimit else { return invalid("Narrow the selected replacement output.") }
        if excludedIDs.isDisjoint(with: ids), let replacementText,
           !result.utf8.elementsEqual(replacementText.utf8) {
            return invalid("The preview edits do not reproduce its replacement text.")
        }
        return .success(result)
    }
}
