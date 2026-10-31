import Foundation

/// A tap-to-start timer found in a step ("3–4 min" → 4 minutes, labelled "3–4 min").
public struct CookTimerSpec: Hashable, Sendable, Identifiable {
    /// Index into `Recipe.steps`.
    public var step: Int
    /// Position among the step's timers.
    public var position: Int
    /// The upper bound, in seconds (the default when started).
    public var seconds: Int
    /// The lower bound of a range ("3–4 min" → 180), else nil.
    public var lowerSeconds: Int?
    /// What the recipe says, shortened: "3–4 min", "30 sec–1 min", "1 ½ min".
    public var label: String
    /// Waiting rather than cooking ("marinating"), from `TimeEstimator.passiveLabel`.
    public var passiveLabel: String?
    /// What the timer is for, from the words before the duration: "Simmer the sauce",
    /// "Cook the onion and bell pepper"; "Marinating" or "Timer" when the clause starts with the time.
    public var title: String

    public var id: String { "\(step).\(position)" }

    /// The durations the cook can pick before starting: the low and high end of a range, or just one.
    public var choices: [Int] {
        guard let lowerSeconds, lowerSeconds > 0, lowerSeconds < seconds else { return [seconds] }
        return [lowerSeconds, seconds]
    }
}

/// Adjusting a running timer and reading a custom duration. Pure, so it's unit-tested here.
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

    /// A custom duration typed by the cook: minutes ("5", "1.5", "1,5", "1 1/2") or "m:ss" ("1:30").
    /// Nil when unreadable, under `minimumSeconds` or over `maximumSeconds`.
    public static func customSeconds(_ text: String) -> Int? {
        let t = text.trimmed
        let seconds: Double
        if let m = Rx.firstMatch("^(\\d{1,3}):(\\d{2})$", in: t),
           let mm = m[1].flatMap(Double.init), let ss = m[2].flatMap(Double.init), ss < 60 {
            seconds = mm * 60 + ss
        } else if Rx.test("^[\\d.,/½¼¾⅓⅔ ]+$", t),
                  let minutes = TimeEstimator.parseNumber(t.replacingOccurrences(of: ",", with: ".")) {
            seconds = minutes * 60
        } else {
            return nil
        }
        guard seconds.isFinite, seconds >= minimumSeconds, seconds <= maximumSeconds else { return nil }
        return Int(seconds.rounded())
    }
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
                    let firstText = text
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
                    if lower == nil { lower = lowerBound(for: text, seconds: seconds) }
                    out.append(CookTimerSpec(step: index, position: out.count, seconds: seconds, lowerSeconds: lower, label: label,
                                             passiveLabel: passive, title: title(in: clause, before: firstText, passive: passive)))
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

    /// The lower end of a written range ("3–4 min" → 180), or nil.
    static func lowerBound(for text: String, seconds: Int) -> Int? {
        let number = "\\d+(?:\\.\\d+)?(?:\\s*[½¼¾⅓⅔]|\\s+\\d+/\\d+)?|\\d+/\\d+|[½¼¾⅓⅔]"
        let pattern = "^(\(number))\\s*(?:-|–|—|to|or)\\s*(\(number))(?:\\s+(?:more|extra|additional|further))?\\s*-?\\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)$"
        guard let m = Rx.firstMatch(pattern, in: text.trimmed), let first = m[1],
              let value = TimeEstimator.parseNumber(first), let unitText = m[3]?.lowercased() else { return nil }
        let scale: Double = unitText.hasPrefix("h") ? 3600 : unitText.hasPrefix("s") ? 1 : 60
        let lower = Int((value * scale).rounded())
        return lower > 0 && lower < seconds ? lower : nil
    }

    /// The words before the duration, trimmed to a short title: "Simmer 2–3 minutes" → "Simmer",
    /// "Cook the onion and bell pepper for 3–4 min" → "Cook the onion and bell pepper".
    static func title(in clause: String, before durationText: String, passive: String?) -> String {
        let ns = clause as NSString
        let at = ns.range(of: durationText)
        let before = at.location == NSNotFound ? "" : ns.substring(to: at.location)
        // Trailing filler before the time: "for about", "another", "a further", "(".
        let filler = "for|about|around|roughly|approximately|approx|another|a further|further|an extra|extra|a|an|or|of|up to|at least|over|in|within|after|the|until"
        // The nearest comma/colon/bracket-separated phrase that says something:
        // "Pour sauce over, mix to coat, set aside to marinate for 10 minutes" → "set aside to marinate".
        var head = ""
        for segment in Rx.replace("[,:;()]", in: before, with: "\u{1}").split(separator: "\u{1}").reversed() {
            var s = Rx.replace("^\\W*(?:(?:and|then|now|next|after that|afterwards)\\b\\W*)+", in: String(segment), with: "")
            s = Rx.replace("(?:[\\s–—-]+|\\b(?:\(filler))\\b)+$", in: s, with: "").trimmed
            if s.count >= 3, Rx.test("[a-z]", s) { head = s; break }
        }
        // Short enough for one Lock Screen line.
        var words: [String] = []
        for word in head.split(separator: " ").map(String.init) {
            if (words + [word]).joined(separator: " ").count > 32 { break }
            words.append(word)
        }
        while let last = words.last,
              Rx.test("^(?:the|a|an|and|or|with|in|on|of|to|into|over|for|your|it|until)$", last) || Rx.test("[,;:]$", last) {
            words.removeLast()
        }
        let title = words.joined(separator: " ")
        guard title.count >= 3, Rx.test("[a-z]", title) else { return RecipeFormatText.capitalisedFirst(passive ?? "timer") }
        return RecipeFormatText.capitalisedFirst(title)
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
