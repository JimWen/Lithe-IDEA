import Foundation

enum ProjectSearchScope: String, CaseIterable, Identifiable {
    case project = "In Project"
    case directory = "Directory"
    case openFiles = "Open Files"
    var id: String { rawValue }
}

struct ProjectSearchPreview: Sendable {
    struct Line: Identifiable, Sendable {
        let number: Int
        let text: String
        var id: Int { number }
    }
    let lines: [Line]
    let message: String?

    static func context(in text: String, line: Int) -> Self {
        let all = text.components(separatedBy: .newlines)
        let selected = min(max(0, line - 1), max(0, all.count - 1))
        let lower = max(0, selected - 7)
        let upper = min(all.count, selected + 9)
        return Self(lines: (lower..<upper).map { Line(number: $0 + 1, text: all[$0]) }, message: nil)
    }
}
