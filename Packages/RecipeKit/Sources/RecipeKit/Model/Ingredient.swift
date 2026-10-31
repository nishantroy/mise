import Foundation

public struct Ingredient: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var raw: String
    public var quantity: Double?
    public var unit: String?
    public var name: String
    public var note: String?
    public var catalogID: String?

    public init(id: UUID = UUID(), raw: String, quantity: Double? = nil, unit: String? = nil,
                name: String, note: String? = nil, catalogID: String? = nil) {
        self.id = id
        self.raw = raw
        self.quantity = quantity
        self.unit = unit
        self.name = name
        self.note = note
        self.catalogID = catalogID
    }

    public func scaled(by factor: Double) -> Ingredient {
        var copy = self
        if let q = quantity { copy.quantity = q * factor }
        return copy
    }

    /// "1 ½ cups flour", "2 cloves garlic", "Salt". Notes are not included (see `note`).
    public var displayText: String {
        var parts: [String] = []
        if let q = quantity { parts.append(QuantityFormatter.string(from: q, unit: unit)) }
        if let u = unit { parts.append(Units.display(u, quantity: quantity)) }
        parts.append(name)
        let text = parts.joined(separator: " ").trimmed
        return text.isEmpty ? raw : text
    }
}
