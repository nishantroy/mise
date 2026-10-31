import Foundation

/// One duration found in a step.
public struct StepDuration: Hashable, Sendable {
    /// Index into `Recipe.steps`.
    public var step: Int
    public var minutes: Double
    /// Waiting rather than cooking, with what kind ("marinating"), else nil.
    public var passiveLabel: String?
    public var isOvernight: Bool
    /// In a "meanwhile" / "while the X cooks" clause: assumed to overlap and not added to the total.
    public var isParallel: Bool
    /// The matched text, e.g. "2–3 minutes".
    public var text: String

    public var isPassive: Bool { passiveLabel != nil }
}

/// What the rules found, before the arithmetic. Also the hints sent to the model.
public struct TimeAnalysis: Hashable, Sendable {
    public struct UntimedStep: Hashable, Sendable {
        public var step: Int
        public var minutes: Double
    }

    public var durations: [StepDuration]
    /// Steps with an "until golden"-style or "bring to a boil" instruction and no time, with the
    /// default minutes the rules give them.
    public var untimed: [UntimedStep]
    /// Ingredients counted for the prep allowance (water, salt and pepper excluded).
    public var prepIngredientCount: Int
    public var prepMinutes: Double

    public var untimedMinutes: Double { untimed.reduce(0) { $0 + $1.minutes } }
    public var activeCookingMinutes: Double { durations.filter { !$0.isParallel && !$0.isPassive }.reduce(0) { $0 + $1.minutes } }
    public var passiveMinutes: Double { durations.filter { !$0.isParallel && $0.isPassive }.reduce(0) { $0 + $1.minutes } }
    public var isOvernight: Bool { durations.contains { $0.isOvernight && !$0.isParallel } }

    /// "marinating" when one kind is at least 75% of the passive time, otherwise "waiting".
    public var passiveLabel: String? {
        let passive = durations.filter { !$0.isParallel && $0.isPassive }
        guard !passive.isEmpty else { return nil }
        if passive.contains(where: \.isOvernight) { return passive.first { $0.isOvernight }?.passiveLabel }
        var byLabel: [String: Double] = [:]
        for d in passive { byLabel[d.passiveLabel ?? "waiting", default: 0] += d.minutes }
        let total = byLabel.values.reduce(0, +)
        guard let top = byLabel.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) else { return nil }
        return top.value >= 0.75 * total ? top.key : "waiting"
    }

    /// Short hint lines for the model, e.g. "step 2: 30 min marinating (waiting)".
    public var hintLines: [String] {
        var lines = durations.prefix(12).map { d -> String in
            let minutes = TimeEstimator.format(d.minutes)
            let kind = d.isOvernight ? "overnight, waiting" : d.passiveLabel.map { "\($0), waiting" } ?? "cooking"
            return "step \(d.step + 1): \(minutes) \(kind)\(d.isParallel ? ", overlaps" : "")"
        }
        let untimedSteps = untimed.map { "\($0.step + 1)" }
        if !untimedSteps.isEmpty { lines.append("untimed steps: \(untimedSteps.joined(separator: ", "))") }
        return lines
    }
}

/// The model's answer for work the recipe doesn't time. Mapped and clamped by `TimeEstimator`.
public struct TimeGapProposal: Hashable, Sendable {
    /// Chopping, measuring and other prep. Replaces the rules' per-ingredient allowance.
    public var prepMinutes: Int
    /// Preheating, boiling water, "until golden" steps. Replaces the rules' untimed defaults.
    public var untimedMinutes: Int
    public var reason: String

    public init(prepMinutes: Int, untimedMinutes: Int, reason: String) {
        self.prepMinutes = prepMinutes
        self.untimedMinutes = untimedMinutes
        self.reason = reason
    }
}

/// Estimates a realistic total time from the steps.
///
/// - Durations are pulled from each step ("4 minutes", "2–3 minutes" → 3, "½ hour", "1 hr 30 min",
///   "30-40 mins" → 40, "a minute", "overnight" → 8 h passive). "1 min on each side" counts twice.
///   Storage advice ("freeze for up to two months") is ignored.
/// - Each is passive when its clause says marinate, rest, chill, refrigerate, rise, proof, soak,
///   set (aside), cool, stand or freeze; otherwise active (simmering and baking count as active).
/// - Clauses starting "Meanwhile" / "While …" or containing "while the X …" are assumed to overlap
///   with the step before and aren't added.
/// - Untimed work gets small defaults: an "until golden" cooking step with no time anywhere in the
///   step gets 3 min; "bring to a boil" with no time in its sentence gets 5 min.
/// - Prep allowance: 1 min per ingredient (water, salt and pepper excluded), at least 5, at most 25.
/// - Total = prep + active + passive, rounded to the nearest 5 (minimum 5).
///
/// Limits: no batch multiplication ("cook in batches"), no awareness of parallel work beyond the
/// "meanwhile" wording, and optional waits ("rest 30 mins if you have time") are counted.
public struct TimeEstimator: Sendable {
    public static let prepMinutesPerIngredient = 1.0
    public static let prepMinimum = 5.0
    public static let prepMaximum = 25.0
    public static let untilDefaultMinutes = 3.0
    public static let boilDefaultMinutes = 5.0
    public static let overnightMinutes = 480.0
    /// Mismatch: the estimate is at least this many times the stated time…
    public static let mismatchRatio = 1.5
    /// …and at least this many minutes longer.
    public static let mismatchMinimumMinutes = 15

    public let catalog: IngredientCatalog

    public init(catalog: IngredientCatalog = .shared) {
        self.catalog = catalog
    }

    // MARK: Estimate

    public func estimate(_ recipe: Recipe, gaps: TimeGapProposal? = nil) -> TimeEstimate {
        let analysis = analyse(recipe)
        var prep = analysis.prepMinutes
        var untimed = analysis.untimedMinutes
        var source = TimeEstimate.Source.rules
        var modelReason: String?
        if let gaps, let mapped = Self.clamp(gaps) {
            prep = Double(mapped.prepMinutes)
            untimed = Double(mapped.untimedMinutes)
            modelReason = mapped.reason
            source = .model
        }
        let active = prep + analysis.activeCookingMinutes + untimed
        let passive = analysis.passiveMinutes
        let total = max(5, Int((active + passive) / 5 + 0.5) * 5)
        let reason = modelReason ?? Self.rulesReason(analysis)
        return TimeEstimate(totalMinutes: total, activeMinutes: Int(active.rounded(.up)),
                            passiveMinutes: Int(passive.rounded(.up)), reason: reason, source: source,
                            passiveLabel: analysis.passiveLabel, isOvernight: analysis.isOvernight)
    }

    /// Model output with absurd values clamped (prep 2–60 min, untimed 0–120 min) and the reason
    /// cut to one line. Nil when the proposal is unusable (negative numbers).
    public static func clamp(_ gaps: TimeGapProposal) -> TimeGapProposal? {
        guard gaps.prepMinutes >= 0, gaps.untimedMinutes >= 0 else { return nil }
        let prep = min(max(gaps.prepMinutes, 2), 60)
        let untimed = min(gaps.untimedMinutes, 120)
        var reason = gaps.reason.split(whereSeparator: \.isNewline).first.map(String.init)?.collapsedWhitespace ?? ""
        if reason.count > 160 { reason = String(reason.prefix(157)).trimmed + "…" }
        if reason.isEmpty { reason = "Includes about \(prep) min of prep and \(untimed) min of untimed cooking." }
        return TimeGapProposal(prepMinutes: prep, untimedMinutes: untimed, reason: reason)
    }

    /// The estimate exceeds the stated time by ≥ 1.5× and ≥ 15 min. False without a stated time.
    public static func isMismatch(estimate: Int, stated: Int?) -> Bool {
        guard let stated, stated > 0 else { return false }
        return Double(estimate) >= mismatchRatio * Double(stated) && estimate - stated >= mismatchMinimumMinutes
    }

    static func rulesReason(_ a: TimeAnalysis) -> String {
        var parts = ["about \(format(a.prepMinutes)) to prep \(a.prepIngredientCount) ingredient\(a.prepIngredientCount == 1 ? "" : "s")"]
        let cooking = a.activeCookingMinutes + a.untimedMinutes
        if cooking > 0 {
            var text = "\(format(cooking)) of cooking"
            if !a.untimed.isEmpty {
                text += " (including ~\(format(a.untimedMinutes)) for \(a.untimed.count) untimed step\(a.untimed.count == 1 ? "" : "s"))"
            }
            parts.append(text)
        }
        if a.isOvernight {
            parts.append("an overnight wait")
        } else if a.passiveMinutes > 0 {
            parts.append("\(format(a.passiveMinutes)) \(a.passiveLabel ?? "waiting")")
        }
        let joined: String
        if parts.count <= 2 {
            joined = parts.joined(separator: " and ")
        } else {
            joined = parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        }
        return RecipeFormatText.capitalisedFirst(joined) + "."
    }

    static func format(_ minutes: Double) -> String {
        let m = Int(minutes.rounded(.up))
        if m >= 60 {
            let h = m / 60, r = m % 60
            return r == 0 ? "\(h) hr" : "\(h) hr \(r) min"
        }
        return "\(max(m, 1)) min"
    }

    // MARK: Analysis

    public func analyse(_ recipe: Recipe) -> TimeAnalysis {
        var durations: [StepDuration] = []
        var untimed: [TimeAnalysis.UntimedStep] = []
        for (index, step) in recipe.steps.enumerated() {
            let sentences = Self.sentences(step)
            let stepParallel = sentences.first.map(Self.startsParallel) ?? false
            var stepDurations: [StepDuration] = []
            var boilMinutes = 0.0
            var untilFound = false
            for sentence in sentences {
                if Self.isStorageAdvice(sentence) { continue }
                var sentenceHasTime = false
                for clause in Self.clauses(sentence) {
                    let parallel = stepParallel || Self.startsParallel(clause) || Self.mentionsWhile(clause)
                    let found = Self.durations(in: clause)
                    if !found.isEmpty { sentenceHasTime = true }
                    let label = Self.passiveLabel(clause)
                    for f in found {
                        stepDurations.append(StepDuration(step: index, minutes: f.minutes,
                                                          passiveLabel: f.overnight ? (label ?? "overnight") : label,
                                                          isOvernight: f.overnight, isParallel: parallel, text: f.text))
                    }
                }
                if !sentenceHasTime && !stepParallel {
                    if Self.bringsToBoil(sentence) { boilMinutes += Self.boilDefaultMinutes }
                    if Self.isUntilCooking(sentence) { untilFound = true }
                }
            }
            durations += stepDurations
            var defaults = boilMinutes
            if stepDurations.isEmpty && untilFound { defaults += Self.untilDefaultMinutes }
            if defaults > 0 { untimed.append(.init(step: index, minutes: defaults)) }
        }
        let skip: Set<String> = ["water", "salt", "black-pepper"]
        let count = recipe.ingredients.filter { ing in
            guard let id = ing.catalogID ?? catalog.match(ing.name)?.id else { return true }
            return !skip.contains(id)
        }.count
        let prep = min(max(Double(count) * Self.prepMinutesPerIngredient, Self.prepMinimum), Self.prepMaximum)
        return TimeAnalysis(durations: durations, untimed: untimed, prepIngredientCount: count, prepMinutes: prep)
    }

    // MARK: Text helpers

    static func sentences(_ text: String) -> [String] {
        // Split after . ! ? followed by whitespace (so "1.5" stays whole).
        Rx.replace("([.!?])\\s+", in: text, with: "$1\u{1}").split(separator: "\u{1}").map { String($0).trimmed }.filter { !$0.isEmpty }
    }

    static func clauses(_ sentence: String) -> [String] {
        Rx.replace("\\s*(?:;|,?\\s+(?:and\\s+)?then\\b)\\s*", in: sentence, with: "\u{1}")
            .split(separator: "\u{1}").map { String($0).trimmed }.filter { !$0.isEmpty }
    }

    static func startsParallel(_ text: String) -> Bool {
        Rx.test("^\\W*(?:meanwhile|in the meantime|while\\b|at the same time)", text)
    }

    static func mentionsWhile(_ text: String) -> Bool {
        Rx.test("\\bwhile (?:the|it|they|that|this|you|your)\\b", text)
    }

    static func isStorageAdvice(_ text: String) -> Bool {
        Rx.test("\\bup to \\S+ (?:days?|weeks?|months?)\\b|\\bleftovers?\\b|\\bairtight\\b|\\bstored?\\b|\\bkeeps? (?:for|in|well)\\b|\\breheat|\\bmake[- ]ahead\\b", text)
    }

    static let passivePatterns: [(pattern: String, label: String)] = [
        ("\\bmarinat\\w*|\\bmarinade\\b", "marinating"),
        ("\\b(?:rise|rising|risen|proof\\w*|prove|proving|double in size)\\b", "rising"),
        ("\\bsoak\\w*", "soaking"),
        ("\\b(?:chill\\w*|refrigerat\\w*|fridge)\\b", "chilling"),
        ("\\bfreez(?:e|ing)\\b", "freezing"),
        ("\\b(?:rest|rests|resting|rested)\\b(?! of\\b)", "resting"),
        ("\\b(?:cool|cools|cooling|cooled)\\b(?! water)", "cooling"),
        ("\\b(?:until set|to set|let (?:it )?set|leave to set)\\b", "setting"),
        ("\\b(?:set aside|stand|standing|let (?:it )?sit|sit for)\\b(?! mixer)", "standing"),
    ]

    /// The kind of waiting a clause describes, or nil when it's active work.
    public static func passiveLabel(_ clause: String) -> String? {
        let text = Rx.replace("\\bthe rest\\b", in: clause, with: "")
        if Rx.test("\\bovernight\\b", text) && passivePatterns.allSatisfy({ !Rx.test($0.pattern, text) }) { return "overnight" }
        return passivePatterns.first { Rx.test($0.pattern, text) }?.label
    }

    static func bringsToBoil(_ sentence: String) -> Bool {
        Rx.test("\\b(?:bring|brought|return)\\b[^.]*?\\bto (?:a |the )?(?:rolling |gentle |full )?(?:boil|simmer)\\b|\\bcomes? (?:up )?to (?:a |the )?(?:boil|simmer)\\b", sentence)
    }

    static func isUntilCooking(_ sentence: String) -> Bool {
        Rx.test("\\b(?:until|till|til)\\b", sentence)
            && Rx.test("\\b(?:cook\\w*|fry|fried|frying|saut[eé]\\w*|simmer\\w*|boil\\w*|bake\\w*|roast\\w*|brown\\w*|heat\\w*|toast\\w*|grill\\w*|sear\\w*|reduc\\w*|caramelis\\w*|carameliz\\w*|soften\\w*|stir\\w*)\\b", sentence)
    }

    // MARK: Duration extraction

    static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
        "forty-five": 45, "forty five": 45, "fifty": 50, "sixty": 60, "ninety": 90,
        "a few": 3, "few": 3, "several": 5, "a couple of": 2, "a couple": 2, "couple of": 2,
        "half an": 0.5, "half a": 0.5,
    ]

    static let fractionGlyphs: [Character: Double] = ["½": 0.5, "¼": 0.25, "¾": 0.75, "⅓": 1.0 / 3, "⅔": 2.0 / 3]

    static let numberPattern: String = {
        let words = numberWords.keys.sorted { $0.count > $1.count }.map { Rx.escape($0) }.joined(separator: "|")
        return "(?:\\d+(?:\\.\\d+)?\\s*[½¼¾⅓⅔]|\\d+\\s+\\d+/\\d+|\\d+/\\d+|\\d+(?:\\.\\d+)?|[½¼¾⅓⅔]|\(words))"
    }()

    static let durationPattern: String = {
        let n = numberPattern
        return "(?<![\\w/.])(\(n))(?:\\s*(?:-|–|—|to|or)\\s*(\(n)))?(?:\\s+(?:more|extra|additional|further))?\\s*-?\\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)\\b"
    }()

    static func parseNumber(_ raw: String) -> Double? {
        let text = raw.lowercased().trimmed
        if let v = numberWords[text] { return v }
        if let last = text.last, let frac = fractionGlyphs[last] {
            let whole = String(text.dropLast()).trimmed
            return (whole.isEmpty ? 0 : Double(whole) ?? 0) + frac
        }
        let parts = text.split(separator: " ")
        if parts.count == 2, let whole = Double(parts[0]), let frac = parseNumber(String(parts[1])) { return whole + frac }
        if text.contains("/") {
            let f = text.split(separator: "/")
            guard f.count == 2, let a = Double(f[0]), let b = Double(f[1]), b > 0 else { return nil }
            return a / b
        }
        return Double(text)
    }

    /// Durations in a piece of text, in minutes. Ranges take the upper value; "1 hr 30 min" and
    /// "an hour and a half" are combined; "overnight" is 8 hours. "Until golden" gives nothing.
    public static func durations(in text: String) -> [(minutes: Double, overnight: Bool, text: String)] {
        let ns = text as NSString
        let regex = Rx.re(durationPattern)
        var raw: [(minutes: Double, unit: Character, range: NSRange)] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let first = ns.substring(with: m.range(at: 1))
            let second = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : nil
            guard var value = parseNumber(first) else { continue }
            if let second, let upper = parseNumber(second) { value = max(value, upper) }
            let unitText = ns.substring(with: m.range(at: 3)).lowercased()
            let unit: Character = unitText.hasPrefix("h") ? "h" : unitText.hasPrefix("s") ? "s" : "m"
            var minutes = unit == "h" ? value * 60 : unit == "s" ? value / 60 : value
            var range = m.range
            let after = ns.substring(from: m.range.location + m.range.length)
            if unit == "h", let half = Rx.firstMatch("^\\s+and a half\\b", in: after) {
                minutes += 30
                range.length += (half[0] ?? "").utf16.count
            }
            let rest = ns.substring(from: range.location + range.length)
            if Rx.test("^\\s+(?:on |per )?(?:each|per|a|the other) side\\b", rest) || Rx.test("^\\s+(?:on )?both sides\\b", rest) {
                minutes *= 2
            }
            raw.append((minutes, unit, range))
        }
        // Combine "1 hr 30 min" / "1 hour and 15 minutes" into one duration.
        var out: [(minutes: Double, overnight: Bool, text: String)] = []
        var i = 0
        while i < raw.count {
            var item = raw[i]
            if item.unit == "h", i + 1 < raw.count, raw[i + 1].unit != "h" {
                let gapStart = item.range.location + item.range.length
                let gap = ns.substring(with: NSRange(location: gapStart, length: raw[i + 1].range.location - gapStart))
                if Rx.test("^\\s*(?:and|,)?\\s*$", gap) {
                    item.minutes += raw[i + 1].minutes
                    item.range = NSRange(location: item.range.location, length: raw[i + 1].range.location + raw[i + 1].range.length - item.range.location)
                    i += 1
                }
            }
            out.append((item.minutes, false, ns.substring(with: item.range)))
            i += 1
        }
        if Rx.test("\\bovernight\\b", text) {
            // "4 hours or overnight": overnight wins; other waits in the same clause are dropped.
            out = [(overnightMinutes, true, "overnight")]
        }
        return out
    }
}

/// Small text helper shared by RecipeKit's insight strings.
enum RecipeFormatText {
    static func capitalisedFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
