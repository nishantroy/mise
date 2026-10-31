import Foundation

/// A tap-to-start timer found in a step. Deterministic: a range uses its high end
/// ("3–4 min" → 4 minutes, labelled "4 min").
public struct CookTimerSpec: Hashable, Sendable, Identifiable {
    /// Index into `Recipe.steps`.
    public var step: Int
    /// Position among the step's timers.
    public var position: Int
    /// The duration in seconds; a range's upper bound.
    public var seconds: Int
    /// The duration as one value: "4 min", "1 ½ min", "30 sec".
    public var label: String
    /// Waiting rather than cooking ("marinating"), from `TimeEstimator.passiveLabel`.
    public var passiveLabel: String?
    /// What the timer is for, at most four words (`TimerLabeler`): "Brown the beef",
    /// "Soak the noodles"; "Step 3 timer" when the rules aren't sure.
    public var title: String

    public var id: String { "\(step).\(position)" }
}

/// Adjusting a running timer. Pure, so it's unit-tested here.
public enum CookTimerAdjust {
    /// "−1 min" never takes a timer below this many seconds.
    public static let minimumSeconds: TimeInterval = 10
    /// The longest timer: 12 hours.
    public static let maximumSeconds: TimeInterval = 12 * 3600

    /// The remaining time after adding `delta` seconds (−60 / +60). Shortening stops at
    /// `minimumSeconds` and never lengthens a timer that already has less than that left.
    public static func adjusted(remaining: TimeInterval, by delta: TimeInterval) -> TimeInterval {
        let target = remaining + delta
        if delta >= 0 { return min(target, max(remaining, maximumSeconds)) }
        return max(target, min(remaining, minimumSeconds))
    }

    /// Whether "−1 min" can do anything.
    public static func canShorten(remaining: TimeInterval) -> Bool { remaining > minimumSeconds }
}

/// Durations in a step, as timers. Reuses `TimeEstimator`'s duration extraction.
///
/// - Ranges use the upper bound, labelled as one value ("2–3 min" → "3 min").
/// - "30 seconds to a minute" is one timer.
/// - "1 min on each side" is a 1 min timer (the estimate counts it twice; a timer is per side).
/// - "Overnight" and storage advice ("keeps for up to 3 days") give no timer.
public enum CookTimers {
    public static func timers(for recipe: Recipe) -> [[CookTimerSpec]] {
        recipe.steps.enumerated().map { timers(in: $0.element, step: $0.offset) }
    }

    public static func timers(in step: String, step index: Int) -> [CookTimerSpec] {
        var out: [CookTimerSpec] = []
        var earlier: [String] = []
        for sentence in TimeEstimator.sentences(step) {
            defer { earlier.append(sentence) }
            guard !TimeEstimator.isStorageAdvice(sentence) else { continue }
            let ns = sentence as NSString
            // Where the previous timer's text ended, so each label reads only its own words.
            var cursor = 0
            for clause in TimeEstimator.clauses(sentence) {
                let found = TimeEstimator.durations(in: clause).filter { !$0.overnight }
                guard !found.isEmpty else { continue }
                let passive = TimeEstimator.passiveLabel(clause)
                var i = 0
                while i < found.count {
                    let firstText = found[i].text
                    var lastText = firstText
                    var seconds = perSideSeconds(found[i])
                    // "30 seconds to a minute": one timer, the high end.
                    if i + 1 < found.count, joinedAsRange(found[i].text, found[i + 1].text, in: clause) {
                        seconds = perSideSeconds(found[i + 1])
                        lastText = found[i + 1].text
                        i += 1
                    }
                    guard seconds > 0 else { i += 1; continue }
                    var start = ns.range(of: firstText, range: NSRange(location: cursor, length: ns.length - cursor))
                    if start.location == NSNotFound { start = NSRange(location: cursor, length: 0) }
                    let tail = start.location + start.length
                    var end = ns.range(of: lastText, range: NSRange(location: start.location, length: ns.length - start.location))
                    if end.location == NSNotFound || end.location < start.location { end = NSRange(location: tail, length: 0) }
                    let endLocation = max(tail, end.location + end.length)
                    let title = TimerLabeler.label(before: ns.substring(with: NSRange(location: cursor, length: start.location - cursor)),
                                                   after: ns.substring(from: endLocation),
                                                   earlier: earlier, step: index)
                    cursor = endLocation
                    out.append(CookTimerSpec(step: index, position: out.count, seconds: seconds, label: format(seconds: seconds),
                                             passiveLabel: passive, title: title))
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
