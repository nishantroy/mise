import Foundation

/// A tap-to-start timer found in a step ("3–4 min" → 4 minutes, labelled "3–4 min").
public struct CookTimerSpec: Hashable, Sendable, Identifiable {
    /// Index into `Recipe.steps`.
    public var step: Int
    /// Position among the step's timers.
    public var position: Int
    /// The upper bound, in seconds.
    public var seconds: Int
    /// What the recipe says, shortened: "3–4 min", "30 sec–1 min", "1 ½ min".
    public var label: String
    /// Waiting rather than cooking ("marinating"), from `TimeEstimator.passiveLabel`.
    public var passiveLabel: String?

    public var id: String { "\(step).\(position)" }
}

/// Durations in a step, as timers. Reuses `TimeEstimator`'s duration extraction.
///
/// - Ranges use the upper bound and keep the range as the label.
/// - "30 seconds to a minute" is one timer.
/// - "1 min on each side" is a 1 min timer (the estimate counts it twice; a timer is per side).
/// - "Overnight" and storage advice ("keeps for up to 3 days") give no timer.
public enum CookTimers {
    public static func timers(for recipe: Recipe) -> [[CookTimerSpec]] {
        recipe.steps.enumerated().map { timers(in: $0.element, step: $0.offset) }
    }

    public static func timers(in step: String, step index: Int) -> [CookTimerSpec] {
        var out: [CookTimerSpec] = []
        for sentence in TimeEstimator.sentences(step) where !TimeEstimator.isStorageAdvice(sentence) {
            for clause in TimeEstimator.clauses(sentence) {
                let found = TimeEstimator.durations(in: clause).filter { !$0.overnight }
                guard !found.isEmpty else { continue }
                let passive = TimeEstimator.passiveLabel(clause)
                var i = 0
                while i < found.count {
                    var text = found[i].text
                    var seconds = perSideSeconds(found[i])
                    var lower: Int?
                    // "30 seconds to a minute": one timer, labelled as a range.
                    if i + 1 < found.count, joinedAsRange(found[i].text, found[i + 1].text, in: clause) {
                        lower = seconds
                        seconds = perSideSeconds(found[i + 1])
                        text = found[i + 1].text
                        i += 1
                    }
                    guard seconds > 0 else { i += 1; continue }
                    let label = lower.map { "\(format(seconds: $0))–\(format(seconds: seconds))" } ?? label(for: text, seconds: seconds)
                    out.append(CookTimerSpec(step: index, position: out.count, seconds: seconds, label: label, passiveLabel: passive))
                    i += 1
                }
            }
        }
        return out
    }

    /// The duration without the "each side" doubling: re-read from its own text.
    static func perSideSeconds(_ found: (minutes: Double, overnight: Bool, text: String)) -> Int {
        let minutes = TimeEstimator.durations(in: found.text).first?.minutes ?? found.minutes
        return Int((minutes * 60).rounded())
    }

    static func joinedAsRange(_ first: String, _ second: String, in clause: String) -> Bool {
        let ns = clause as NSString
        let a = ns.range(of: first)
        guard a.location != NSNotFound else { return false }
        let rest = NSRange(location: a.location + a.length, length: ns.length - a.location - a.length)
        let b = ns.range(of: second, range: rest)
        guard b.location != NSNotFound else { return false }
        let gap = ns.substring(with: NSRange(location: rest.location, length: b.location - rest.location))
        return Rx.test("^\\s*(?:to|or|-|–|—)\\s*$", gap)
    }

    /// "2-3 minutes" → "2–3 min", "1 1/2 minutes" → "1 ½ min", "10 seconds" → "10 sec".
    /// Word numbers ("a few seconds", "half an hour") are labelled from the value.
    static func label(for text: String, seconds: Int) -> String {
        let number = "\\d+(?:\\.\\d+)?(?:\\s*[½¼¾⅓⅔]|\\s+\\d+/\\d+)?|\\d+/\\d+|[½¼¾⅓⅔]"
        let pattern = "^(\(number))(?:\\s*(?:-|–|—|to|or)\\s*(\(number)))?(?:\\s+(?:more|extra|additional|further))?\\s*-?\\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)$"
        guard let m = Rx.firstMatch(pattern, in: text.trimmed), let first = m[1], let unitText = m[3] else {
            return format(seconds: seconds)
        }
        let unit = unitText.lowercased().hasPrefix("h") ? "hr" : unitText.lowercased().hasPrefix("s") ? "sec" : "min"
        func tidy(_ n: String) -> String {
            guard let v = TimeEstimator.parseNumber(n) else { return n }
            if v == v.rounded() { return String(Int(v)) }
            return QuantityFormatter.string(from: v)
        }
        if let second = m[2] { return "\(tidy(first))–\(tidy(second)) \(unit)" }
        return "\(tidy(first)) \(unit)"
    }

    /// 45 → "45 sec", 90 → "1 ½ min", 600 → "10 min", 5400 → "1 hr 30 min".
    public static func format(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) sec" }
        if seconds < 3600 {
            let minutes = Double(seconds) / 60
            return minutes == minutes.rounded() ? "\(Int(minutes)) min" : "\(QuantityFormatter.string(from: minutes)) min"
        }
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    /// A running clock: "4:05", "1:02:30".
    public static func clock(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
