import AppKit

@MainActor
final class MacTerminalFontCatalog: TerminalFontCatalogProviding {
    func availableFonts() -> [TerminalFontChoice] {
        let manager = NSFontManager.shared
        return Set(manager.availableFonts).compactMap { name in
            guard let font = NSFont(name: name, size: 13), font.fontName == name else { return nil }
            return TerminalFontChoice(id: name, displayName: font.displayName ?? name,
                                      isMonospaced: manager.traits(of: font).contains(.fixedPitchFontMask))
        }.sorted { $0.displayName == $1.displayName ? $0.id < $1.id : $0.displayName < $1.displayName }
    }
}
