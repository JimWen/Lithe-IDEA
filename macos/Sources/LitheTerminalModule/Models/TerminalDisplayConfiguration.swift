import Foundation

/// Display preferences are independent of a shell's immutable launch snapshot.
/// Typography is one atomic group: an unavailable font keeps the prior group.
public struct TerminalDisplayConfiguration: Codable, Equatable, Sendable {
    public static let fontSizeRange = 8.0...48.0
    public static let lineSpacingRange = 1.0...2.0
    public static let maximumFallbacks = 8
    public static let maximumFontNameBytes = 256

    /// A PostScript identifier; nil uses the platform's preferred terminal font.
    public var fontName: String?
    public var fontSize: Double = 13
    public var fallbackFontNames: [String] = []
    public var lineSpacing: Double = 1

    public init() {}

    private enum CodingKeys: CodingKey {
        case fontName, fontSize, fallbackFontNames, lineSpacing
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try values.decodeIfPresent(String.self, forKey: .fontName)
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        fallbackFontNames = try values.decodeIfPresent([String].self, forKey: .fallbackFontNames) ?? []
        lineSpacing = try values.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 1
    }

    public var validationMessage: String? {
        guard fontSize.isFinite, Self.fontSizeRange.contains(fontSize) else {
            return "Terminal font size must be between 8 and 48 points."
        }
        guard lineSpacing.isFinite, Self.lineSpacingRange.contains(lineSpacing) else {
            return "Terminal line height must be between 1 and 2."
        }
        guard fallbackFontNames.count <= Self.maximumFallbacks else {
            return "Terminal settings allow at most 8 fallback fonts."
        }
        let names = (fontName.map { [$0] } ?? []) + fallbackFontNames
        guard names.allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) && $0.utf8.count <= Self.maximumFontNameBytes }) else {
            return "Choose a valid terminal font identifier."
        }
        guard Set(names).count == names.count else {
            return "Each terminal font must be unique."
        }
        return nil
    }
}
