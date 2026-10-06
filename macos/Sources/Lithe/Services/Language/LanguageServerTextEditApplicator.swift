import Foundation

enum LanguageServerTextEditApplicator {
    enum Error: LocalizedError, Equatable {
        case invalidRange
        case overlappingEdits

        var errorDescription: String? {
            switch self {
            case .invalidRange: "Language server returned an invalid text range."
            case .overlappingEdits: "Language server returned overlapping text edits."
            }
        }
    }

    static func apply(_ edits: [LanguageServerTextEdit], to text: String) throws -> String {
        // Validate exact UTF-16 boundaries before Core's permissive LSP
        // position conversion, so malformed edits cannot be silently clamped.
        let replacements = try validatedReplacements(edits, in: text)
        let core = RustCoreBridge()
        if core.isAvailable {
            switch core.applyLanguageServerTextEdits(edits, to: text) {
            case .success(let payload):
                return payload.text
            case .failure(let error):
                switch error.details {
                case "overlappingEdits": throw Error.overlappingEdits
                default: throw Error.invalidRange
                }
            }
        }
        return applyFallback(replacements, to: text)
    }

    private static func validatedReplacements(_ edits: [LanguageServerTextEdit], in text: String) throws -> [(NSRange, String)] {
        var indexed: [(NSRange, String, Int)] = []
        for (index, edit) in edits.enumerated() {
            indexed.append((try range(edit.range, in: text), edit.newText, index))
        }
        let replacements = indexed.sorted { lhs, rhs in
            lhs.0.location == rhs.0.location ? lhs.2 < rhs.2 : lhs.0.location < rhs.0.location
        }
        for index in 1..<max(1, replacements.count) {
            guard NSMaxRange(replacements[index - 1].0) <= replacements[index].0.location else { throw Error.overlappingEdits }
        }
        return replacements.map { ($0.0, $0.1) }
    }

    private static func applyFallback(_ replacements: [(NSRange, String)], to text: String) -> String {
        let mutable = NSMutableString(string: text)
        // Equal-position inserts retain their input order after reverse apply.
        for (range, replacement) in replacements.reversed() { mutable.replaceCharacters(in: range, with: replacement) }
        return mutable as String
    }

    static func range(_ range: LanguageServerRange, in text: String) throws -> NSRange {
        let units = Array(text.utf16)
        func offset(_ position: LanguageServerPosition) -> Int? {
            guard position.line >= 0, position.utf16Column >= 0 else { return nil }
            var line = 0
            var start = 0
            for (index, unit) in units.enumerated() where unit == 10 && line < position.line {
                start = index + 1
                line += 1
            }
            guard line == position.line else { return nil }
            let newline = units[start...].firstIndex(of: 10)
            var end = newline ?? units.count
            if newline != nil, end > start, units[end - 1] == 13 { end -= 1 }
            guard position.utf16Column <= end - start else { return nil }
            let offset = start + position.utf16Column
            if offset < units.count, (0xDC00...0xDFFF).contains(units[offset]) { return nil }
            return offset
        }
        guard let start = offset(range.start), let end = offset(range.end), end >= start else { throw Error.invalidRange }
        return NSRange(location: start, length: end - start)
    }

}

enum LanguageServerSnippet {
    static func plainText(_ value: String) -> String {
        if let text = RustCoreBridge().plainLanguageServerSnippet(value) {
            return text
        }
        var result = value
        if let placeholders = try? NSRegularExpression(pattern: #"\$\{\d+:([^}]*)\}"#) {
            result = placeholders.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: "$1"
            )
        }
        if let tabStops = try? NSRegularExpression(pattern: #"\$\{?\d+\}?"#) {
            result = tabStops.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: ""
            )
        }
        return result
    }
}
