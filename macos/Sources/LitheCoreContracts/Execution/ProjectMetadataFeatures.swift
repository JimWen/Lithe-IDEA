import Foundation

/// Swift String keys compare canonically equivalent Unicode as equal. Cargo
/// feature names instead keep their original bytes, just like the Core map.
package struct ProjectMetadataFeature: Decodable, Equatable, Sendable, Identifiable {
    package let name: String
    package let enables: [String]
    /// Use within a member's feature list; names must not become Swift Set keys.
    package var id: String {
        Data(name.utf8).base64EncodedString()
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name.utf8.elementsEqual(rhs.name.utf8)
            && lhs.enables.count == rhs.enables.count
            && zip(lhs.enables, rhs.enables).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
}
