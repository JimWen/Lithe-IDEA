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
    struct Expanded: Equatable, Sendable {
        let text: String
        let selectionUTF16Range: NSRange
    }

    /// Expands LSP snippet placeholders (`$0`, `$1`, `${1:default}`, `${1|a,b|}`)
    /// into plain insertion text plus the initial caret/placeholder UTF-16 range.
    static func expand(_ value: String) -> Expanded {
        let chars = Array(value)
        var output = ""
        var utf16Offset = 0
        var tabStops: [Int: NSRange] = [:]
        var index = 0

        func appendText(_ chunk: String) {
            output.append(chunk)
            utf16Offset += chunk.utf16.count
        }

        func recordTabStop(_ number: Int, range: NSRange) {
            if tabStops[number] == nil {
                tabStops[number] = range
            }
        }

        while index < chars.count {
            let ch = chars[index]
            if ch == "\\", index + 1 < chars.count {
                let next = chars[index + 1]
                if next == "$" || next == "}" || next == "\\" {
                    appendText(String(next))
                    index += 2
                    continue
                }
            }
            if ch == "$", index + 1 < chars.count {
                let next = chars[index + 1]
                if next.isASCII, next.isNumber {
                    var cursor = index + 1
                    var digits = ""
                    while cursor < chars.count, chars[cursor].isASCII, chars[cursor].isNumber {
                        digits.append(chars[cursor])
                        cursor += 1
                    }
                    if let number = Int(digits) {
                        recordTabStop(number, range: NSRange(location: utf16Offset, length: 0))
                        index = cursor
                        continue
                    }
                } else if next == "{" {
                    if let parsed = parseBracedSnippet(chars, from: index + 2) {
                        let startOffset = utf16Offset
                        appendText(parsed.resolvedText)
                        let endOffset = utf16Offset
                        if let number = parsed.tabStopNumber {
                            recordTabStop(
                                number,
                                range: NSRange(location: startOffset, length: endOffset - startOffset)
                            )
                        }
                        index = parsed.nextIndex
                        continue
                    }
                }
            }
            appendText(String(ch))
            index += 1
        }

        let selection: NSRange
        if let firstPositive = tabStops.keys.filter({ $0 > 0 }).min(),
           let range = tabStops[firstPositive] {
            selection = range
        } else if let finalStop = tabStops[0] {
            selection = finalStop
        } else {
            selection = NSRange(location: utf16Offset, length: 0)
        }
        return Expanded(text: output, selectionUTF16Range: selection)
    }

    private struct ParsedBracedSnippet {
        let tabStopNumber: Int?
        let resolvedText: String
        let nextIndex: Int
    }

    private static func parseBracedSnippet(
        _ chars: [Character],
        from start: Int
    ) -> ParsedBracedSnippet? {
        var cursor = start
        var digits = ""
        while cursor < chars.count, chars[cursor].isASCII, chars[cursor].isNumber {
            digits.append(chars[cursor])
            cursor += 1
        }
        guard !digits.isEmpty, let tabStop = Int(digits), cursor < chars.count else {
            return nil
        }
        if chars[cursor] == "}" {
            return ParsedBracedSnippet(tabStopNumber: tabStop, resolvedText: "", nextIndex: cursor + 1)
        }
        if chars[cursor] == "|" {
            // Choice syntax: ${1|one,two,three|}
            cursor += 1
            var choiceBody = ""
            while cursor + 1 < chars.count {
                if chars[cursor] == "|" && chars[cursor + 1] == "}" {
                    let firstChoice = choiceBody.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                        .first.map(String.init) ?? ""
                    return ParsedBracedSnippet(
                        tabStopNumber: tabStop,
                        resolvedText: firstChoice,
                        nextIndex: cursor + 2
                    )
                }
                choiceBody.append(chars[cursor])
                cursor += 1
            }
            return nil
        }
        if chars[cursor] == ":" {
            cursor += 1
            var depth = 1
            var rawInner = ""
            while cursor < chars.count {
                let c = chars[cursor]
                if c == "\\", cursor + 1 < chars.count {
                    let escaped = chars[cursor + 1]
                    if escaped == "}" || escaped == "$" || escaped == "\\" {
                        // Preserve escape sequences so the recursive `expand(rawInner)`
                        // unescapes them once without reinterpreting `\$100` as a tabstop.
                        rawInner.append("\\")
                        rawInner.append(escaped)
                        cursor += 2
                        continue
                    }
                }
                if c == "$" && cursor + 1 < chars.count && chars[cursor + 1] == "{" {
                    depth += 1
                    rawInner.append(c)
                    rawInner.append("{")
                    cursor += 2
                    continue
                }
                if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        let nested = expand(rawInner)
                        return ParsedBracedSnippet(
                            tabStopNumber: tabStop,
                            resolvedText: nested.text,
                            nextIndex: cursor + 1
                        )
                    }
                }
                rawInner.append(c)
                cursor += 1
            }
        }
        return nil
    }

    static func plainText(_ value: String) -> String {
        if let text = RustCoreBridge().plainLanguageServerSnippet(value) {
            return text
        }
        return expand(value).text
    }
}
