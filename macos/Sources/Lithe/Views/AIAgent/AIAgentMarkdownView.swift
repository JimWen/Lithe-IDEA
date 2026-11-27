import AppKit
import SwiftUI

enum AIAgentMarkdownTableAlignment: Equatable {
    case leading
    case center
    case trailing
}

struct AIAgentMarkdownListItem: Equatable {
    let text: String
    let indentLevel: Int
    let isTask: Bool
    let isChecked: Bool
}

enum AIAgentMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case bulletList(items: [AIAgentMarkdownListItem])
    case orderedList(start: Int, items: [AIAgentMarkdownListItem])
    case blockquote(lines: [String])
    case codeBlock(language: String, code: String, isClosed: Bool)
    case table(headers: [String], alignments: [AIAgentMarkdownTableAlignment], rows: [[String]])
    case thematicBreak
}

/// Deterministic single-pass block-level Markdown parser designed for live
/// streaming AI Agent output without WebView overhead.
enum AIAgentMarkdownParser {
    static func parse(_ markdown: String) -> [AIAgentMarkdownBlock] {
        guard !markdown.isEmpty else { return [] }
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [AIAgentMarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            // Fenced code blocks (``` or ~~~)
            if let fence = parseFenceOpening(trimmed) {
                var codeLines: [String] = []
                index += 1
                var isClosed = false
                while index < lines.count {
                    let candidate = lines[index]
                    if isFenceClosing(candidate.trimmingCharacters(in: .whitespaces), marker: fence.marker, minLength: fence.length) {
                        isClosed = true
                        index += 1
                        break
                    }
                    codeLines.append(candidate)
                    index += 1
                }
                blocks.append(.codeBlock(
                    language: fence.language,
                    code: codeLines.joined(separator: "\n"),
                    isClosed: isClosed
                ))
                continue
            }

            // Thematic break (---, ***, ___)
            if isThematicBreak(trimmed) {
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            // ATX Headings (# .. ######)
            if let heading = parseHeading(trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            // GFM Pipe Tables
            if index + 1 < lines.count,
               let headerCells = parseTableRow(line),
               let alignments = parseTableSeparator(lines[index + 1], expectedColumns: headerCells.count) {
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let rowLine = lines[index]
                    let rowTrimmed = rowLine.trimmingCharacters(in: .whitespaces)
                    if rowTrimmed.isEmpty || isBlockStart(rowLine) {
                        break
                    }
                    guard let cells = parseTableRow(rowLine) else { break }
                    var padded = Array(cells.prefix(headerCells.count))
                    while padded.count < headerCells.count {
                        padded.append("")
                    }
                    rows.append(padded)
                    index += 1
                }
                blocks.append(.table(headers: headerCells, alignments: alignments, rows: rows))
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var content = String(candidate.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    quoteLines.append(content)
                    index += 1
                }
                blocks.append(.blockquote(lines: quoteLines))
                continue
            }

            // Unordered / task list
            if parseBulletItem(line) != nil {
                var items: [AIAgentMarkdownListItem] = []
                while index < lines.count, let item = parseBulletItem(lines[index]) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.bulletList(items: items))
                continue
            }

            // Ordered list
            if let firstOrdered = parseOrderedItem(line) {
                var items: [AIAgentMarkdownListItem] = [firstOrdered.item]
                let startNumber = firstOrdered.number
                index += 1
                while index < lines.count, let nextOrdered = parseOrderedItem(lines[index]) {
                    items.append(nextOrdered.item)
                    index += 1
                }
                blocks.append(.orderedList(start: startNumber, items: items))
                continue
            }

            // Paragraph (collect consecutive non-block lines)
            var paragraphLines: [String] = [line]
            index += 1
            while index < lines.count {
                let candidate = lines[index]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                if candidateTrimmed.isEmpty || isBlockStart(candidate) {
                    break
                }
                if index + 1 < lines.count,
                   let headers = parseTableRow(candidate),
                   parseTableSeparator(lines[index + 1], expectedColumns: headers.count) != nil {
                    break
                }
                paragraphLines.append(candidate)
                index += 1
            }
            blocks.append(.paragraph(text: paragraphLines.joined(separator: "\n")))
        }

        return blocks
    }

    private static func isBlockStart(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return parseFenceOpening(trimmed) != nil
            || isThematicBreak(trimmed)
            || parseHeading(trimmed) != nil
            || trimmed.hasPrefix(">")
            || parseBulletItem(line) != nil
            || parseOrderedItem(line) != nil
    }

    private static func parseFenceOpening(_ trimmed: String) -> (marker: Character, length: Int, language: String)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        var count = 0
        for ch in trimmed {
            if ch == first { count += 1 } else { break }
        }
        guard count >= 3 else { return nil }
        let rest = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        if first == "`" && rest.contains("`") { return nil }
        let language = rest.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return (first, count, language)
    }

    private static func isFenceClosing(_ trimmed: String, marker: Character, minLength: Int) -> Bool {
        guard trimmed.count >= minLength else { return false }
        return trimmed.allSatisfy { $0 == marker }
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3, let first = stripped.first,
              first == "-" || first == "*" || first == "_" else {
            return false
        }
        return stripped.allSatisfy { $0 == first }
    }

    private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let remainder = trimmed.dropFirst(level)
        guard remainder.first == " " || remainder.first == "\t" else { return nil }
        var text = String(remainder).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") && text.dropLast().hasSuffix(" ") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return (level, text)
    }

    private static func parseBulletItem(_ line: String) -> AIAgentMarkdownListItem? {
        let leadingSpaces = line.prefix { $0 == " " || $0 == "\t" }
        let indentWidth = leadingSpaces.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        let remainder = line.dropFirst(leadingSpaces.count)
        guard let marker = remainder.first,
              marker == "-" || marker == "*" || marker == "+" else {
            return nil
        }
        let afterMarker = remainder.dropFirst()
        guard afterMarker.first == " " || afterMarker.first == "\t" else { return nil }
        let rawText = String(afterMarker).trimmingCharacters(in: .whitespaces)
        let indentLevel = min(3, indentWidth / 2)

        if rawText.hasPrefix("[ ] ") {
            return AIAgentMarkdownListItem(
                text: String(rawText.dropFirst(4)),
                indentLevel: indentLevel,
                isTask: true,
                isChecked: false
            )
        }
        if rawText.hasPrefix("[x] ") || rawText.hasPrefix("[X] ") {
            return AIAgentMarkdownListItem(
                text: String(rawText.dropFirst(4)),
                indentLevel: indentLevel,
                isTask: true,
                isChecked: true
            )
        }
        return AIAgentMarkdownListItem(
            text: rawText,
            indentLevel: indentLevel,
            isTask: false,
            isChecked: false
        )
    }

    private static func parseOrderedItem(_ line: String) -> (number: Int, item: AIAgentMarkdownListItem)? {
        let leadingSpaces = line.prefix { $0 == " " || $0 == "\t" }
        let indentWidth = leadingSpaces.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        let remainder = line.dropFirst(leadingSpaces.count)
        let digits = remainder.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4, let number = Int(digits) else { return nil }
        let afterDigits = remainder.dropFirst(digits.count)
        guard let punct = afterDigits.first, punct == "." || punct == ")" else { return nil }
        let afterPunct = afterDigits.dropFirst()
        guard afterPunct.first == " " || afterPunct.first == "\t" else { return nil }
        let text = String(afterPunct).trimmingCharacters(in: .whitespaces)
        return (
            number,
            AIAgentMarkdownListItem(
                text: text,
                indentLevel: min(3, indentWidth / 2),
                isTask: false,
                isChecked: false
            )
        )
    }

    private static func parseTableRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var body = trimmed
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") && !hasOddTrailingBackslashes(beforeLastIn: body) {
            body.removeLast()
        }
        let chars = Array(body)
        var cells: [String] = []
        var current = ""
        var index = 0
        var inCodeTicks = 0
        while index < chars.count {
            let ch = chars[index]
            if ch == "`" {
                var run = 0
                while index + run < chars.count && chars[index + run] == "`" {
                    run += 1
                }
                if inCodeTicks == 0 {
                    inCodeTicks = run
                } else if inCodeTicks == run {
                    inCodeTicks = 0
                }
                current.append(contentsOf: repeatElement("`", count: run))
                index += run
                continue
            }
            if ch == "\\" && index + 1 < chars.count && chars[index + 1] == "|" {
                // Only unescape `\|` (GFM table delimiter escape); preserve all other backslashes
                // such as `\d+\s` or `\n` verbatim for display, copy, and inline parsing.
                current.append("|")
                index += 2
                continue
            }
            if ch == "|" && inCodeTicks == 0 {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                index += 1
                continue
            }
            current.append(ch)
            index += 1
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.count >= 2 ? cells : nil
    }

    private static func hasOddTrailingBackslashes(beforeLastIn text: String) -> Bool {
        guard text.count >= 2 else { return false }
        var count = 0
        var idx = text.index(before: text.endIndex)
        while idx > text.startIndex {
            idx = text.index(before: idx)
            if text[idx] == "\\" {
                count += 1
            } else {
                break
            }
        }
        return count % 2 == 1
    }

    private static func parseTableSeparator(
        _ line: String,
        expectedColumns: Int
    ) -> [AIAgentMarkdownTableAlignment]? {
        guard let cells = parseTableRow(line), cells.count == expectedColumns else { return nil }
        var alignments: [AIAgentMarkdownTableAlignment] = []
        for cell in cells {
            let clean = cell.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { return nil }
            let startsColon = clean.hasPrefix(":")
            let endsColon = clean.hasSuffix(":")
            var inner = clean
            if startsColon { inner.removeFirst() }
            if endsColon, !inner.isEmpty { inner.removeLast() }
            guard inner.count >= 1, inner.allSatisfy({ $0 == "-" }) else { return nil }
            if startsColon && endsColon {
                alignments.append(.center)
            } else if endsColon {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        return alignments
    }
}

/// Bounded cache of syntax-highlighted code blocks so scrolling or streaming
/// other turns never re-lexes unchanged fenced code snippets.
@MainActor
private final class AIAgentCodeHighlightCache {
    static let shared = AIAgentCodeHighlightCache()

    private final class Entry: NSObject {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private let cache: NSCache<NSString, Entry> = {
        let store = NSCache<NSString, Entry>()
        store.countLimit = 128
        return store
    }()

    func highlighted(code: String, language: String, isDark: Bool) -> AttributedString {
        let normalizedExtension = Self.fileExtension(forLanguageTag: language)
        let cacheKey = "\(isDark ? "d" : "l")|\(normalizedExtension)|\(code.hashValue)|\(code.utf8.count)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached.value
        }

        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let storage = NSTextStorage(string: code)
        SyntaxHighlighter.apply(
            to: storage,
            font: font,
            fileName: normalizedExtension == "gomod" ? "go.mod" : nil,
            fileExtension: normalizedExtension,
            isDark: isDark
        )
        let result = AttributedString(storage)
        cache.setObject(Entry(result), forKey: cacheKey)
        return result
    }

    static func fileExtension(forLanguageTag raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "go", "golang": "go"
        case "go.mod", "gomod": "gomod"
        case "rs", "rust": "rs"
        case "py", "python", "python3": "py"
        case "swift": "swift"
        case "js", "javascript", "jsx": "js"
        case "ts", "typescript", "tsx": "ts"
        case "json", "jsonc": "json"
        case "yaml", "yml": "yaml"
        case "toml": "toml"
        case "xml", "html", "svg": "xml"
        case "sh", "bash", "zsh", "shell": "sh"
        case "sql": "sql"
        case "c", "h": "c"
        case "cpp", "c++", "cxx", "cc", "hpp": "cpp"
        case "java": "java"
        case "kt", "kotlin": "kt"
        case "rb", "ruby": "rb"
        case "lua": "lua"
        case "ini": "ini"
        case "env", "dotenv": "env"
        case "properties": "properties"
        case "diff", "patch": "txt"
        default: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}

/// Native SwiftUI block-level Markdown renderer for AI Agent turns.
/// Supports headings, lists/tasks, blockquotes, horizontal-scroll tables,
/// inline code/emphasis/links, and syntax-highlighted fenced code blocks.
struct AIAgentMarkdownBlockView: View, Equatable {
    let text: String

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text
    }

    var body: some View {
        let blocks = AIAgentMarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: AIAgentMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            VStack(alignment: .leading, spacing: 3) {
                inlineText(content)
                    .font(headingFont(for: level))
                    .foregroundStyle(LitheTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if level <= 2 {
                    Rectangle()
                        .fill(LitheTheme.divider.opacity(0.75))
                        .frame(height: 1)
                }
            }
            .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let content):
            inlineText(content)
                .font(.system(size: 12.5))
                .foregroundStyle(LitheTheme.primaryText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if item.isTask {
                            Image(systemName: item.isChecked ? "checkmark.square.fill" : "square")
                                .font(.system(size: 11))
                                .foregroundStyle(item.isChecked ? LitheTheme.success : LitheTheme.tertiaryText)
                        } else {
                            Text(item.indentLevel == 0 ? "•" : "◦")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        inlineText(item.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(LitheTheme.primaryText)
                            .lineSpacing(1.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(item.indentLevel) * 12)
                }
            }

        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(start + offset).")
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .frame(minWidth: 18, alignment: .trailing)
                        inlineText(item.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(LitheTheme.primaryText)
                            .lineSpacing(1.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(item.indentLevel) * 12)
                }
            }

        case .blockquote(let lines):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(LitheTheme.accent.opacity(0.65))
                    .frame(width: 3)
                inlineText(lines.joined(separator: "\n"))
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(LitheTheme.raised.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .codeBlock(let language, let code, _):
            AIAgentMarkdownCodeBlockView(language: language, code: code)

        case .table(let headers, let alignments, let rows):
            tableView(headers: headers, alignments: alignments, rows: rows)

        case .thematicBreak:
            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: .system(size: 15.5, weight: .bold)
        case 2: .system(size: 14, weight: .bold)
        case 3: .system(size: 13, weight: .semibold)
        default: .system(size: 12.5, weight: .semibold)
        }
    }

    private func inlineText(_ raw: String) -> Text {
        if var attributed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            for run in attributed.runs {
                if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                    attributed[run.range].font = .system(size: 11.5, design: .monospaced)
                    attributed[run.range].foregroundColor = LitheTheme.accent
                    attributed[run.range].backgroundColor = LitheTheme.raised.opacity(0.75)
                }
                if run.link != nil {
                    attributed[run.range].foregroundColor = LitheTheme.accent
                    attributed[run.range].underlineStyle = .single
                }
            }
            return Text(attributed)
        }
        return Text(raw)
    }

    private func tableView(
        headers: [String],
        alignments: [AIAgentMarkdownTableAlignment],
        rows: [[String]]
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { colIndex, header in
                        inlineText(header)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LitheTheme.primaryText)
                            .multilineTextAlignment(textAlignment(alignments[safe: colIndex]))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: frameAlignment(alignments[safe: colIndex]))
                            .background(LitheTheme.raised.opacity(0.8))
                    }
                }

                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                            inlineText(cell)
                                .font(.system(size: 11))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .multilineTextAlignment(textAlignment(alignments[safe: colIndex]))
                                .textSelection(.enabled)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: frameAlignment(alignments[safe: colIndex]))
                                .background(rowIndex.isMultiple(of: 2) ? LitheTheme.inputBackground : LitheTheme.raised.opacity(0.35))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.divider, lineWidth: 1))
        }
    }

    private func textAlignment(_ alignment: AIAgentMarkdownTableAlignment?) -> TextAlignment {
        switch alignment ?? .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func frameAlignment(_ alignment: AIAgentMarkdownTableAlignment?) -> Alignment {
        switch alignment ?? .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

private struct AIAgentMarkdownCodeBlockView: View {
    @Environment(\.colorScheme) private var colorScheme
    let language: String
    let code: String
    @State private var didCopy = false
    @State private var resetCopyTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    didCopy = true
                    resetCopyTask?.cancel()
                    resetCopyTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1500))
                        guard !Task.isCancelled else { return }
                        didCopy = false
                    }
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(didCopy ? LitheTheme.success : LitheTheme.secondaryText)
                .lithePointer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(LitheTheme.raised.opacity(0.75))

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(AIAgentCodeHighlightCache.shared.highlighted(
                    code: code,
                    language: language,
                    isDark: colorScheme == .dark
                ))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(LitheTheme.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.divider, lineWidth: 1))
        .onDisappear {
            resetCopyTask?.cancel()
            resetCopyTask = nil
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
