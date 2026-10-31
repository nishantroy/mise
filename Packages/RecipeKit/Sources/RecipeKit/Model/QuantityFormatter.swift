import Foundation

/// Formats quantities the way recipes write them: 0.5 → "½", 1.25 → "1 ¼", 250 → "250".
public enum QuantityFormatter {
    private static let fractions: [(value: Double, glyph: String)] = [
        (0, ""), (1.0 / 8, "⅛"), (1.0 / 4, "¼"), (1.0 / 3, "⅓"), (1.0 / 2, "½"),
        (2.0 / 3, "⅔"), (3.0 / 4, "¾"), (1, ""),
    ]
    /// Metric and weight units read better as whole or decimal numbers than as fractions.
    private static let decimalUnits: Set<String> = ["g", "kg", "ml", "l", "oz", "fl oz", "lb"]

    public static func string(from value: Double, unit: String? = nil) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        if let unit, decimalUnits.contains(unit) {
            if value >= 10 { return String(Int(roundSensibly(value))) }
            return trimDecimal(value)
        }
        if value >= 10 { return String(Int(value.rounded())) }
        var whole = value.rounded(.down)
        let frac = value - whole
        let nearest = fractions.min { abs($0.value - frac) < abs($1.value - frac) }!
        if nearest.value == 1 { whole += 1 }
        let glyph = nearest.value == 1 ? "" : nearest.glyph
        switch (whole, glyph) {
        case (0, ""): return "⅛"  // never show 0 for a real, tiny amount
        case (0, _): return glyph
        case (_, ""): return String(Int(whole))
        default: return "\(Int(whole)) \(glyph)"
        }
    }

    /// 237 → 235, 1003 → 1000, 12.4 → 12. Keeps metric amounts tidy after scaling.
    private static func roundSensibly(_ value: Double) -> Double {
        if value >= 100 { return (value / 5).rounded() * 5 }
        return value.rounded()
    }

    private static func trimDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }
}
