import Foundation

/// Display preferences are independent of a shell's immutable launch snapshot.
/// Typography is one atomic group: an unavailable font keeps the prior group.
public struct TerminalDisplayConfiguration: Codable, Equatable, Sendable {
    public static let fontSizeRange = 8.0...48.0
    public static let lineSpacingRange = 1.0...2.0
    public static let maximumFallbacks = 8
    public static let maximumFontNameBytes = 256
    public static let scrollbackRange = 0...100_000
    public static let scrollSensitivityRange = 0.05...10.0

    public enum CursorShape: String, Codable, CaseIterable, Sendable { case block, underline, bar }
    public enum LinkDetection: String, Codable, CaseIterable, Sendable { case automatic, explicit, disabled }
    public enum LinkModifier: String, Codable, CaseIterable, Sendable { case command, none }

    /// A PostScript identifier; nil uses the platform's preferred terminal font.
    public var fontName: String?
    public var fontSize: Double = 13
    public var fallbackFontNames: [String] = []
    public var lineSpacing: Double = 1
    public var scrollback: Int = 2_000
    public var cursorShape: CursorShape = .block
    public var cursorBlink: Bool = true
    public var optionAsMeta: Bool = true
    public var scrollSensitivity: Double = 1
    public var copyOnSelect: Bool = false
    public var keepSelectionOnCopy: Bool = true
    public var linkDetection: LinkDetection = .automatic
    public var linkModifier: LinkModifier = .command

    public init() {}

    private enum CodingKeys: CodingKey {
        case fontName, fontSize, fallbackFontNames, lineSpacing
        case scrollback, cursorShape, cursorBlink, optionAsMeta, scrollSensitivity
        case copyOnSelect, keepSelectionOnCopy, linkDetection, linkModifier
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try values.decodeIfPresent(String.self, forKey: .fontName)
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        fallbackFontNames = try values.decodeIfPresent([String].self, forKey: .fallbackFontNames) ?? []
        lineSpacing = try values.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 1
        scrollback = try values.decodeIfPresent(Int.self, forKey: .scrollback) ?? 2_000
        cursorShape = try values.decodeIfPresent(CursorShape.self, forKey: .cursorShape) ?? .block
        cursorBlink = try values.decodeIfPresent(Bool.self, forKey: .cursorBlink) ?? true
        optionAsMeta = try values.decodeIfPresent(Bool.self, forKey: .optionAsMeta) ?? true
        scrollSensitivity = try values.decodeIfPresent(Double.self, forKey: .scrollSensitivity) ?? 1
        copyOnSelect = try values.decodeIfPresent(Bool.self, forKey: .copyOnSelect) ?? false
        keepSelectionOnCopy = try values.decodeIfPresent(Bool.self, forKey: .keepSelectionOnCopy) ?? true
        linkDetection = try values.decodeIfPresent(LinkDetection.self, forKey: .linkDetection) ?? .automatic
        linkModifier = try values.decodeIfPresent(LinkModifier.self, forKey: .linkModifier) ?? .command
    }

    public var validationMessage: String? {
        typographyValidationMessage ?? scrollbackValidationMessage ?? scrollSensitivityValidationMessage
    }

    public var scrollbackValidationMessage: String? {
        Self.scrollbackRange.contains(scrollback) ? nil : "Terminal history must be between 0 and 100000 lines."
    }

    public var scrollSensitivityValidationMessage: String? {
        scrollSensitivity.isFinite && Self.scrollSensitivityRange.contains(scrollSensitivity)
            ? nil : "Terminal scroll sensitivity must be between 0.05 and 10."
    }

    public var typographyValidationMessage: String? {
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
