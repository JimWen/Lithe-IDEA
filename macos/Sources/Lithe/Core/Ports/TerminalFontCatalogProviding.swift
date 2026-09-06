import Foundation

struct TerminalFontChoice: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let isMonospaced: Bool
}

/// Settings can inspect fonts without activating the terminal module or a PTY.
@MainActor
protocol TerminalFontCatalogProviding {
    func availableFonts() -> [TerminalFontChoice]
}
