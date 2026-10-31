import Foundation

/// ISO 8601 durations as used in schema.org recipes ("PT1H30M", "P0DT2H", "PT90M").
public enum ISODuration {
    /// Total minutes, rounded; nil if the string isn't a duration or is zero.
    public static func minutes(_ text: String?) -> Int? {
        guard let text = text?.trimmed, !text.isEmpty,
              let m = Rx.firstMatch("^P(?:(\\d+(?:\\.\\d+)?)Y)?(?:(\\d+(?:\\.\\d+)?)M)?(?:(\\d+(?:\\.\\d+)?)W)?(?:(\\d+(?:\\.\\d+)?)D)?(?:T(?:(\\d+(?:\\.\\d+)?)H)?(?:(\\d+(?:\\.\\d+)?)M)?(?:(\\d+(?:\\.\\d+)?)S)?)?$", in: text)
        else { return nil }
        func v(_ i: Int) -> Double { m[i].flatMap(Double.init) ?? 0 }
        // Years and months are nonsense for recipes but appear in broken markup; ignore them.
        let total = v(3) * 7 * 1440 + v(4) * 1440 + v(5) * 60 + v(6) + v(7) / 60
        let rounded = Int(total.rounded())
        return rounded > 0 ? rounded : nil
    }
}
