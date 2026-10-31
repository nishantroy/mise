import Foundation

/// What the user has told us about their kitchen. Keys are catalog IDs, or normalised names
/// for ingredients the catalog doesn't know.
public struct PantrySnapshot: Codable, Hashable, Sendable {
    public var have: Set<String>
    public var missing: Set<String>

    public init(have: Set<String> = [], missing: Set<String> = []) {
        self.have = have
        self.missing = missing
    }

    public static let empty = PantrySnapshot()
}
