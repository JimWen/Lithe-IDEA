import SwiftUI

/// Compact project identity used in the main toolbar and project switcher.
struct ProjectBadge: View {
    let name: String
    var size: CGFloat = 20

    static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard let first = words.first?.first else { return "?" }
        guard words.count > 1, let last = words.last?.first else {
            return String(first).uppercased()
        }
        return String([first, last]).uppercased()
    }

    private var color: Color {
        let colors: [Color] = [
            Color(red: 0.60, green: 0.32, blue: 0.83),
            Color(red: 0.18, green: 0.61, blue: 0.70),
            Color(red: 0.31, green: 0.47, blue: 0.78),
            Color(red: 0.72, green: 0.40, blue: 0.29),
            Color(red: 0.31, green: 0.60, blue: 0.42),
            Color(red: 0.68, green: 0.34, blue: 0.56)
        ]
        // Swift's randomized hash would change the project color on every launch.
        let hash = name.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return colors[Int(hash % UInt64(colors.count))]
    }

    var body: some View {
        Text(Self.initials(for: name))
            .font(.system(size: size * 0.6, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }
}
