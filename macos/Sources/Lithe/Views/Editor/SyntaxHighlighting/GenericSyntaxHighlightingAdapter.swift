import AppKit
import LitheCoreContracts

/// Single-pass lexical highlighter for source languages not handled by a
/// dedicated structured-config adapter.
///
/// Consuming strings and comments atomically in one left-to-right pass ensures
/// comment markers inside string literals (for example `"return // marker"` or
/// `"return # marker"`) stay string-colored and keywords inside comments or
/// strings are never mis-colored. Lexical profiles are supplied declaratively
/// by `LanguageSyntaxProfileRegistry` (built-in highlight-only profiles and
/// activated official language plugins). Line-ending state is cached on
/// `NSTextStorage` so incremental edits resume in O(1) and stop scanning once
/// multiline state converges.
enum GenericSyntaxHighlightingAdapter {
    private enum LexerState: Equatable {
        case normal
        case blockComment(depth: Int)
        case backtickString
        case tripleDoubleString
        case tripleSingleString
        case rustDoubleString
        case rustRawString(hashes: Int)

        var encoded: String {
            switch self {
            case .normal: return "n"
            case .blockComment(let depth): return "bc:\(depth)"
            case .backtickString: return "bt"
            case .tripleDoubleString: return "td"
            case .tripleSingleString: return "ts"
            case .rustDoubleString: return "rd"
            case .rustRawString(let hashes): return "rr:\(hashes)"
            }
        }

        init?(encoded: String) {
            if encoded == "n" { self = .normal; return }
            if encoded == "bt" { self = .backtickString; return }
            if encoded == "td" { self = .tripleDoubleString; return }
            if encoded == "ts" { self = .tripleSingleString; return }
            if encoded == "rd" { self = .rustDoubleString; return }
            if encoded.hasPrefix("bc:"), let depth = Int(encoded.dropFirst(3)), depth > 0 {
                self = .blockComment(depth: depth)
                return
            }
            if encoded.hasPrefix("rr:"), let hashes = Int(encoded.dropFirst(3)), hashes >= 0 {
                self = .rustRawString(hashes: hashes)
                return
            }
            return nil
        }
    }

    private static let multilineStateAttribute = NSAttributedString.Key("lithe.generic.multiline-state")

    @discardableResult
    static func apply(
        to storage: NSTextStorage,
        palette: SyntaxHighlightingPalette,
        range target: NSRange,
        fileExtension: String = "",
        fileName: String? = nil
    ) -> Int {
        let source = storage.string as NSString
        guard source.length > 0, target.length > 0 else { return 0 }

        let profile = LanguageSyntaxProfileRegistry.shared.profile(
            forFileName: fileName,
            fileExtension: fileExtension
        )
        let profileTag = profile.languageID
        let scanStart = lineRange(containing: target.location, in: source).location
        let requiredEnd = NSMaxRange(lineRange(containing: max(target.location, NSMaxRange(target) - 1), in: source))

        let cachedBeforeTarget = cachedState(at: scanStart - 1, profileTag: profileTag, in: storage)
        let shouldConverge = cachedBeforeTarget != nil
            || cachedState(afterLineEndingAt: requiredEnd, profileTag: profileTag, in: storage) != nil
        var state = cachedBeforeTarget ?? .normal
        var scannedLineCount = 0

        if cachedBeforeTarget == nil, scanStart > 0 {
            var prefixLineStart = 0
            while prefixLineStart < scanStart {
                let range = source.lineRange(for: NSRange(location: prefixLineStart, length: 0))
                scanLine(
                    in: source,
                    lineRange: range,
                    profile: profile,
                    palette: palette,
                    storage: nil,
                    state: &state
                )
                cache(state: state, profileTag: profileTag, after: range, in: storage)
                prefixLineStart = NSMaxRange(range)
                scannedLineCount += 1
            }
        }

        storage.removeAttribute(
            multilineStateAttribute,
            range: NSRange(location: scanStart, length: max(0, requiredEnd - scanStart))
        )

        var lineStart = scanStart
        while lineStart < source.length {
            let range = source.lineRange(for: NSRange(location: lineStart, length: 0))
            let cachedExit = cachedState(after: range, profileTag: profileTag, in: storage)
            storage.addAttribute(.foregroundColor, value: palette.text, range: range)
            scanLine(
                in: source,
                lineRange: range,
                profile: profile,
                palette: palette,
                storage: storage,
                state: &state
            )
            cache(state: state, profileTag: profileTag, after: range, in: storage)
            scannedLineCount += 1
            lineStart = NSMaxRange(range)

            if shouldStop(
                after: range,
                requiredEnd: requiredEnd,
                shouldConverge: shouldConverge,
                cachedExitState: cachedExit,
                currentState: state
            ) {
                break
            }
        }
        return scannedLineCount
    }

    static func apply(
        _ expression: NSRegularExpression,
        color: NSColor,
        storage: NSTextStorage,
        range: NSRange
    ) {
        expression.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private static func scanLine(
        in source: NSString,
        lineRange: NSRange,
        profile: LanguageSyntaxProfile,
        palette: SyntaxHighlightingPalette,
        storage: NSTextStorage?,
        state: inout LexerState
    ) {
        let contentRange = lineContentRange(in: source, lineRange: lineRange)
        let limit = NSMaxRange(contentRange)
        var cursor = contentRange.location

        while cursor < limit {
            switch state {
            case .blockComment(var depth):
                let start = cursor
                while cursor < limit {
                    let ch = source.character(at: cursor)
                    if profile.supportsNestedBlockComments,
                       ch == 47, cursor + 1 < limit, source.character(at: cursor + 1) == 42 {
                        depth += 1
                        cursor += 2
                        continue
                    }
                    if ch == 42, cursor + 1 < limit, source.character(at: cursor + 1) == 47 {
                        depth -= 1
                        cursor += 2
                        if depth == 0 {
                            state = .normal
                            break
                        }
                        continue
                    }
                    cursor += 1
                }
                if depth > 0 { state = .blockComment(depth: depth) }
                paint(palette.comment, range: NSRange(location: start, length: cursor - start), to: storage)
                continue

            case .backtickString:
                let start = cursor
                while cursor < limit {
                    let ch = source.character(at: cursor)
                    if profile.backtickAllowsEscape, ch == 92, cursor + 1 < limit {
                        cursor += 2
                        continue
                    }
                    cursor += 1
                    if ch == 96 {
                        state = .normal
                        break
                    }
                }
                paint(palette.string, range: NSRange(location: start, length: cursor - start), to: storage)
                continue

            case .tripleDoubleString, .tripleSingleString:
                let quote: unichar = state == .tripleDoubleString ? 34 : 39
                let start = cursor
                while cursor < limit {
                    let ch = source.character(at: cursor)
                    if ch == 92, cursor + 1 < limit {
                        cursor += 2
                        continue
                    }
                    if ch == quote,
                       cursor + 2 < limit,
                       source.character(at: cursor + 1) == quote,
                       source.character(at: cursor + 2) == quote {
                        cursor += 3
                        state = .normal
                        break
                    }
                    cursor += 1
                }
                paint(palette.string, range: NSRange(location: start, length: cursor - start), to: storage)
                continue

            case .rustDoubleString:
                let start = cursor
                while cursor < limit {
                    let ch = source.character(at: cursor)
                    if ch == 92, cursor + 1 < limit {
                        cursor += 2
                        continue
                    }
                    cursor += 1
                    if ch == 34 {
                        state = .normal
                        break
                    }
                }
                paint(palette.string, range: NSRange(location: start, length: cursor - start), to: storage)
                continue

            case .rustRawString(let hashes):
                let start = cursor
                while cursor < limit {
                    if source.character(at: cursor) == 34,
                       matchesHashCount(hashes, in: source, at: cursor + 1, limit: limit) {
                        cursor += 1 + hashes
                        state = .normal
                        break
                    }
                    cursor += 1
                }
                paint(palette.string, range: NSRange(location: start, length: cursor - start), to: storage)
                continue

            case .normal:
                break
            }

            let ch = source.character(at: cursor)

            // Line comments (`//` or `#`)
            if profile.supportsSlashComments, ch == 47, cursor + 1 < limit {
                let next = source.character(at: cursor + 1)
                if next == 47 {
                    paint(palette.comment, range: NSRange(location: cursor, length: limit - cursor), to: storage)
                    return
                }
                if profile.supportsBlockComments, next == 42 {
                    let start = cursor
                    cursor += 2
                    state = .blockComment(depth: 1)
                    // Paint opening delimiter; loop continues immediately in .blockComment state.
                    paint(palette.comment, range: NSRange(location: start, length: 2), to: storage)
                    continue
                }
            }
            if profile.supportsHashComments, ch == 35 {
                paint(palette.comment, range: NSRange(location: cursor, length: limit - cursor), to: storage)
                return
            }
            if profile.supportsDashComments, ch == 45, cursor + 1 < limit, source.character(at: cursor + 1) == 45 {
                paint(palette.comment, range: NSRange(location: cursor, length: limit - cursor), to: storage)
                return
            }

            // Rust attributes: `#[...]` / `#![...]`
            if profile.supportsRustSyntax, ch == 35 {
                if let attrEnd = rustAttributeEnd(in: source, from: cursor, limit: limit) {
                    paint(palette.annotation, range: NSRange(location: cursor, length: attrEnd - cursor), to: storage)
                    cursor = attrEnd
                    continue
                }
            }

            // `@annotation` / `@decorator`
            if profile.supportsAtAnnotations, ch == 64,
               cursor + 1 < limit, isIdentifierStart(source.character(at: cursor + 1)) {
                let start = cursor
                cursor += 2
                while cursor < limit {
                    let unit = source.character(at: cursor)
                    if isIdentifierContinue(unit) || (profile.supportsTripleQuotedStrings && unit == 46) {
                        cursor += 1
                    } else {
                        break
                    }
                }
                paint(palette.annotation, range: NSRange(location: start, length: cursor - start), to: storage)
                continue
            }

            // Rust raw strings: `r"..."`, `r#"..."#`, `br#"..."#`, `cr#"..."#`
            if profile.supportsRustSyntax,
               let rawStart = rustRawStringPrefix(in: source, at: cursor, lineStart: contentRange.location, limit: limit) {
                let start = cursor
                cursor = rawStart.contentStart
                state = .rustRawString(hashes: rawStart.hashes)
                paint(palette.string, range: NSRange(location: start, length: cursor - start), to: storage)
                continue
            }

            // Rust byte/c strings: `b"..."`, `c"..."`, `b'x'`
            if profile.supportsRustSyntax,
               (ch == 98 || ch == 99),
               !isPrecededByIdentifier(in: source, at: cursor, lineStart: contentRange.location),
               cursor + 1 < limit {
                let next = source.character(at: cursor + 1)
                if next == 34 {
                    let start = cursor
                    cursor += 2
                    state = .rustDoubleString
                    paint(palette.string, range: NSRange(location: start, length: 2), to: storage)
                    continue
                }
                if ch == 98, next == 39,
                   let end = rustCharLiteralEnd(in: source, quoteAt: cursor + 1, limit: limit) {
                    paint(palette.string, range: NSRange(location: cursor, length: end - cursor), to: storage)
                    cursor = end
                    continue
                }
            }

            // Python prefixed strings (`r"..."`, `f'...'`, `rb"""..."""`, etc.)
            if profile.supportsTripleQuotedStrings,
               let pyPrefix = pythonStringPrefix(in: source, at: cursor, lineStart: contentRange.location, limit: limit) {
                let start = cursor
                let quote = pyPrefix.quote
                if pyPrefix.isTriple {
                    cursor = pyPrefix.quoteStart + 3
                    state = quote == 34 ? .tripleDoubleString : .tripleSingleString
                    paint(palette.string, range: NSRange(location: start, length: cursor - start), to: storage)
                } else {
                    let end = scanSingleLineString(in: source, quote: quote, from: pyPrefix.quoteStart + 1, limit: limit, allowsEscape: true)
                    paint(palette.string, range: NSRange(location: start, length: end - start), to: storage)
                    cursor = end
                }
                continue
            }

            // Double-quoted strings
            if ch == 34 {
                if profile.supportsTripleQuotedStrings,
                   cursor + 2 < limit,
                   source.character(at: cursor + 1) == 34,
                   source.character(at: cursor + 2) == 34 {
                    paint(palette.string, range: NSRange(location: cursor, length: 3), to: storage)
                    cursor += 3
                    state = .tripleDoubleString
                    continue
                }
                if profile.supportsRustSyntax {
                    paint(palette.string, range: NSRange(location: cursor, length: 1), to: storage)
                    cursor += 1
                    state = .rustDoubleString
                    continue
                }
                let end = scanSingleLineString(in: source, quote: 34, from: cursor + 1, limit: limit, allowsEscape: true)
                paint(palette.string, range: NSRange(location: cursor, length: end - cursor), to: storage)
                cursor = end
                continue
            }

            // Single-quoted strings / runes / Rust char literals (without breaking Rust `'a` lifetimes)
            if ch == 39 {
                if profile.supportsRustSyntax {
                    if let end = rustCharLiteralEnd(in: source, quoteAt: cursor, limit: limit) {
                        paint(palette.string, range: NSRange(location: cursor, length: end - cursor), to: storage)
                        cursor = end
                        continue
                    }
                    // Rust lifetime (`'a`, `'static`, `'_`): advance past `'` and its identifier.
                    cursor += 1
                    while cursor < limit, isIdentifierContinue(source.character(at: cursor)) {
                        cursor += 1
                    }
                    continue
                }
                if profile.supportsTripleQuotedStrings,
                   cursor + 2 < limit,
                   source.character(at: cursor + 1) == 39,
                   source.character(at: cursor + 2) == 39 {
                    paint(palette.string, range: NSRange(location: cursor, length: 3), to: storage)
                    cursor += 3
                    state = .tripleSingleString
                    continue
                }
                let end = scanSingleLineString(
                    in: source,
                    quote: 39,
                    from: cursor + 1,
                    limit: limit,
                    allowsEscape: profile.singleQuoteAllowsEscape
                )
                paint(palette.string, range: NSRange(location: cursor, length: end - cursor), to: storage)
                cursor = end
                continue
            }

            // Backtick raw / template strings (Go, JS/TS)
            if ch == 96, profile.supportsBacktickMultilineStrings {
                paint(palette.string, range: NSRange(location: cursor, length: 1), to: storage)
                cursor += 1
                state = .backtickString
                continue
            }

            // Numbers
            if isAsciiDigit(ch) {
                let start = cursor
                cursor = scanNumberEnd(in: source, from: cursor, limit: limit)
                paint(palette.number, range: NSRange(location: start, length: cursor - start), to: storage)
                continue
            }

            // Identifiers, keywords, and types
            if isIdentifierStart(ch) {
                let start = cursor
                cursor += 1
                while cursor < limit, isIdentifierContinue(source.character(at: cursor)) {
                    cursor += 1
                }
                if storage != nil {
                    let wordRange = NSRange(location: start, length: cursor - start)
                    let word = source.substring(with: wordRange)
                    if profile.keywords.contains(word) {
                        paint(palette.keyword, range: wordRange, to: storage)
                    } else if profile.builtinTypes.contains(word) || isUpperCamelIdentifier(word, firstUnit: ch) {
                        paint(palette.type, range: wordRange, to: storage)
                    }
                }
                continue
            }

            cursor += 1
        }
    }

    private static func paint(_ color: NSColor, range: NSRange, to storage: NSTextStorage?) {
        guard let storage, range.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: color, range: range)
    }

    private static func scanSingleLineString(
        in source: NSString,
        quote: unichar,
        from start: Int,
        limit: Int,
        allowsEscape: Bool
    ) -> Int {
        var cursor = start
        while cursor < limit {
            let ch = source.character(at: cursor)
            if allowsEscape, ch == 92, cursor + 1 < limit {
                cursor += 2
                continue
            }
            cursor += 1
            if ch == quote {
                return cursor
            }
        }
        return limit
    }

    private static func rustCharLiteralEnd(in source: NSString, quoteAt start: Int, limit: Int) -> Int? {
        let next = start + 1
        guard next < limit else { return nil }
        let first = source.character(at: next)
        if first == 92 {
            // Escaped character literal (`'\n'`, `'\''`, `'\x7f'`, `'\u{1F600}'`)
            var cursor = next + 1
            let maxEnd = min(limit, start + 14)
            if cursor < maxEnd { cursor += 1 }
            while cursor < maxEnd {
                let unit = source.character(at: cursor)
                if unit == 39 { return cursor + 1 }
                if unit == 10 || unit == 13 { return nil }
                cursor += 1
            }
            return nil
        }
        if first == 39 { return nil }
        if next + 1 < limit, source.character(at: next + 1) == 39 {
            return next + 2
        }
        // Surrogate pair character literal (`'😀'`)
        if (0xD800...0xDBFF).contains(first),
           next + 2 < limit,
           (0xDC00...0xDFFF).contains(source.character(at: next + 1)),
           source.character(at: next + 2) == 39 {
            return next + 3
        }
        return nil
    }

    private static func rustRawStringPrefix(
        in source: NSString,
        at start: Int,
        lineStart: Int,
        limit: Int
    ) -> (hashes: Int, contentStart: Int)? {
        guard !isPrecededByIdentifier(in: source, at: start, lineStart: lineStart) else { return nil }
        let ch = source.character(at: start)
        var cursor = start
        if ch == 114 { // 'r'
            cursor += 1
        } else if (ch == 98 || ch == 99), cursor + 1 < limit, source.character(at: cursor + 1) == 114 { // "br" / "cr"
            cursor += 2
        } else {
            return nil
        }
        var hashes = 0
        while cursor < limit, source.character(at: cursor) == 35 {
            hashes += 1
            cursor += 1
        }
        guard cursor < limit, source.character(at: cursor) == 34 else { return nil }
        return (hashes, cursor + 1)
    }

    private static func rustAttributeEnd(in source: NSString, from start: Int, limit: Int) -> Int? {
        var cursor = start + 1
        if cursor < limit, source.character(at: cursor) == 33 { cursor += 1 }
        guard cursor < limit, source.character(at: cursor) == 91 else { return nil }
        var depth = 0
        while cursor < limit {
            let unit = source.character(at: cursor)
            if unit == 34 {
                cursor = scanSingleLineString(in: source, quote: 34, from: cursor + 1, limit: limit, allowsEscape: true)
                continue
            }
            if unit == 91 { depth += 1 }
            else if unit == 93 {
                depth -= 1
                if depth == 0 { return cursor + 1 }
            }
            cursor += 1
        }
        return limit
    }

    private static func pythonStringPrefix(
        in source: NSString,
        at start: Int,
        lineStart: Int,
        limit: Int
    ) -> (quote: unichar, quoteStart: Int, isTriple: Bool)? {
        guard !isPrecededByIdentifier(in: source, at: start, lineStart: lineStart) else { return nil }
        guard isPythonPrefixChar(source.character(at: start)) else { return nil }
        var quoteStart = start + 1
        if quoteStart < limit, isPythonPrefixChar(source.character(at: quoteStart)) {
            quoteStart += 1
        }
        guard quoteStart < limit else { return nil }
        let quote = source.character(at: quoteStart)
        guard quote == 34 || quote == 39 else { return nil }
        let isTriple = quoteStart + 2 < limit
            && source.character(at: quoteStart + 1) == quote
            && source.character(at: quoteStart + 2) == quote
        return (quote, quoteStart, isTriple)
    }

    private static func isPythonPrefixChar(_ unit: unichar) -> Bool {
        switch unit {
        case 82, 114, 85, 117, 66, 98, 70, 102: true // R/r, U/u, B/b, F/f
        default: false
        }
    }

    private static func matchesHashCount(_ count: Int, in source: NSString, at start: Int, limit: Int) -> Bool {
        guard start + count <= limit else { return false }
        for offset in 0..<count where source.character(at: start + offset) != 35 {
            return false
        }
        return true
    }

    private static func scanNumberEnd(in source: NSString, from start: Int, limit: Int) -> Int {
        var cursor = start + 1
        if source.character(at: start) == 48, cursor < limit {
            let prefix = source.character(at: cursor)
            if prefix == 120 || prefix == 88 || prefix == 98 || prefix == 66 || prefix == 111 || prefix == 79 {
                cursor += 1
                while cursor < limit, isHexOrUnderscore(source.character(at: cursor)) {
                    cursor += 1
                }
                while cursor < limit, isIdentifierContinue(source.character(at: cursor)) {
                    cursor += 1
                }
                return cursor
            }
        }
        var seenDot = false
        while cursor < limit {
            let unit = source.character(at: cursor)
            if isAsciiDigit(unit) || unit == 95 {
                cursor += 1
            } else if unit == 46, !seenDot, cursor + 1 < limit, isAsciiDigit(source.character(at: cursor + 1)) {
                seenDot = true
                cursor += 2
            } else if unit == 101 || unit == 69 {
                let next = cursor + 1
                if next < limit, (source.character(at: next) == 43 || source.character(at: next) == 45) {
                    cursor += 2
                } else {
                    cursor += 1
                }
            } else if isIdentifierStart(unit) {
                // Numeric suffixes such as Rust `10u64` / `1.0f32` or Go `1i`.
                cursor += 1
                while cursor < limit, isIdentifierContinue(source.character(at: cursor)) {
                    cursor += 1
                }
                break
            } else {
                break
            }
        }
        return cursor
    }

    private static func isPrecededByIdentifier(in source: NSString, at index: Int, lineStart: Int) -> Bool {
        index > lineStart && isIdentifierContinue(source.character(at: index - 1))
    }

    private static func isAsciiDigit(_ unit: unichar) -> Bool {
        unit >= 48 && unit <= 57
    }

    private static func isHexOrUnderscore(_ unit: unichar) -> Bool {
        isAsciiDigit(unit) || (unit >= 65 && unit <= 70) || (unit >= 97 && unit <= 102) || unit == 95
    }

    private static func isIdentifierStart(_ unit: unichar) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
    }

    private static func isIdentifierContinue(_ unit: unichar) -> Bool {
        isIdentifierStart(unit) || isAsciiDigit(unit)
    }

    private static func isUpperCamelIdentifier(_ word: String, firstUnit: unichar) -> Bool {
        firstUnit >= 65 && firstUnit <= 90 && word.count >= 2
    }

    private static func cache(
        state: LexerState,
        profileTag: String,
        after lineRange: NSRange,
        in storage: NSTextStorage
    ) {
        guard lineRange.length > 0 else { return }
        storage.addAttribute(
            multilineStateAttribute,
            value: "\(profileTag)|\(state.encoded)",
            range: NSRange(location: NSMaxRange(lineRange) - 1, length: 1)
        )
    }

    private static func cachedState(
        at location: Int,
        profileTag: String,
        in storage: NSTextStorage
    ) -> LexerState? {
        guard location >= 0, location < storage.length,
              let value = storage.attribute(multilineStateAttribute, at: location, effectiveRange: nil) as? String else {
            return nil
        }
        let prefix = "\(profileTag)|"
        guard value.hasPrefix(prefix) else { return nil }
        return LexerState(encoded: String(value.dropFirst(prefix.count)))
    }

    private static func cachedState(
        after lineRange: NSRange,
        profileTag: String,
        in storage: NSTextStorage
    ) -> LexerState? {
        cachedState(at: NSMaxRange(lineRange) - 1, profileTag: profileTag, in: storage)
    }

    private static func cachedState(
        afterLineEndingAt location: Int,
        profileTag: String,
        in storage: NSTextStorage
    ) -> LexerState? {
        guard location < storage.length else { return nil }
        let source = storage.string as NSString
        let nextLine = source.lineRange(for: NSRange(location: location, length: 0))
        return cachedState(after: nextLine, profileTag: profileTag, in: storage)
    }

    private static func shouldStop(
        after lineRange: NSRange,
        requiredEnd: Int,
        shouldConverge: Bool,
        cachedExitState: LexerState?,
        currentState: LexerState
    ) -> Bool {
        let lineEnd = NSMaxRange(lineRange)
        guard lineEnd >= requiredEnd else { return false }
        guard shouldConverge else { return true }
        guard lineRange.location >= requiredEnd else { return false }
        return cachedExitState == currentState
    }

    private static func lineRange(containing location: Int, in source: NSString) -> NSRange {
        source.lineRange(
            for: NSRange(location: min(max(0, location), max(0, source.length - 1)), length: 0)
        )
    }

    private static func lineContentRange(in source: NSString, lineRange: NSRange) -> NSRange {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let character = source.character(at: end - 1)
            guard character == 10 || character == 13 else { break }
            end -= 1
        }
        return NSRange(location: lineRange.location, length: end - lineRange.location)
    }
}
