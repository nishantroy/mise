import Foundation

/// Unit vocabulary used by the ingredient parser and display.
public enum Units {
    /// Canonical unit → accepted spellings (lowercased, without trailing ".").
    static let table: [(canonical: String, forms: [String])] = [
        ("tsp", ["tsp", "tsps", "teaspoon", "teaspoons", "t"]),
        ("tbsp", ["tbsp", "tbsps", "tbs", "tbl", "tablespoon", "tablespoons"]),
        ("cup", ["cup", "cups", "c"]),
        ("g", ["g", "gm", "gms", "gr", "gram", "grams", "gramme", "grammes"]),
        ("kg", ["kg", "kgs", "kilo", "kilos", "kilogram", "kilograms"]),
        ("ml", ["ml", "mls", "millilitre", "millilitres", "milliliter", "milliliters"]),
        ("l", ["l", "litre", "litres", "liter", "liters"]),
        ("oz", ["oz", "ounce", "ounces"]),
        ("fl oz", ["fl oz", "fluid ounce", "fluid ounces"]),
        ("lb", ["lb", "lbs", "pound", "pounds"]),
        ("clove", ["clove", "cloves"]),
        ("can", ["can", "cans", "tin", "tins"]),
        ("pinch", ["pinch", "pinches"]),
        ("dash", ["dash", "dashes"]),
        ("slice", ["slice", "slices"]),
        ("stalk", ["stalk", "stalks"]),
        ("sprig", ["sprig", "sprigs"]),
        ("bunch", ["bunch", "bunches"]),
        ("handful", ["handful", "handfuls"]),
        ("inch", ["inch", "inches", "in"]),
        ("piece", ["piece", "pieces"]),
        ("packet", ["packet", "packets", "package", "packages", "pack", "packs"]),
    ]

    /// Case-sensitive single-letter forms: "T" = tbsp, "t" = tsp. Others are matched lowercased.
    static func canonical(for token: String) -> String? {
        if token == "T" { return "tbsp" }
        if token == "t" { return "tsp" }
        if token == "C" { return "cup" }
        let lower = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard lower.count > 1 else { return lower == "g" || lower == "l" ? lower : nil }
        return table.first { $0.forms.contains(lower) }?.canonical
    }

    /// Units that read naturally with a plural "s" ("2 cups", "3 cloves").
    static let countable: Set<String> = ["cup", "clove", "can", "slice", "stalk", "sprig", "piece", "packet", "handful"]

    public static func display(_ unit: String, quantity: Double?) -> String {
        guard let q = quantity, q > 1.0001 else { return unit }
        if countable.contains(unit) { return unit + "s" }
        if unit == "pinch" || unit == "dash" || unit == "bunch" { return unit + "es" }
        if unit == "inch" { return "inches" }
        return unit
    }
}
