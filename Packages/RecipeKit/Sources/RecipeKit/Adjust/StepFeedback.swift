import Foundation

/// A heat setting as recipes write it ("on low", "medium-high heat").
public enum HeatLevel: String, Hashable, Sendable {
    case low, mediumLow = "medium-low", medium, mediumHigh = "medium-high", high

    /// Longest first, so "medium-low" wins over "medium".
    static let pattern = "medium[- ]low|medium[- ]high|med[- ]low|med[- ]high|medium|moderate|low|high|full|max(?:imum)?"

    static func parse(_ raw: String) -> HeatLevel? {
        switch Rx.replace("[\\s-]+", in: raw.lowercased(), with: "-") {
        case "low": .low
        case "medium-low", "med-low": .mediumLow
        case "medium", "med", "moderate": .medium
        case "medium-high", "med-high": .mediumHigh
        case "high", "full", "max", "maximum": .high
        default: nil
        }
    }
}

/// What one clause of "I made this" feedback says about a step, and what to do about it.
public struct StepChange: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        /// A deterministic rewrite of the step (untouched text kept verbatim).
        case rewrite(String)
        /// Drop the step: the cook skipped it and no ingredient is lost with it.
        case remove
        /// Understood and targeted, but no safe rewrite: a note tied to the step
        /// ("Step 7 (Chicken): did it in the oven at 200°C"). The model may turn it into a rewrite.
        case note(String)
    }

    public var stepIndex: Int
    public var outcome: Outcome
    /// The feedback clause, as typed (tidied).
    public var clause: String
    /// Whether the on-device model should try to rewrite the step (method, order, or a time or
    /// heat change the rules couldn't place). Skips never go to the model.
    public var wantsModel: Bool

    public var edit: RecipeEdit {
        switch outcome {
        case let .rewrite(text): .updateStep(index: stepIndex, text: text)
        case .remove: .removeStep(index: stepIndex)
        case let .note(text): .addNote(text)
        }
    }
}

/// What a clause says about cooking, before it is tied to a step.
struct StepSignal: Hashable, Sendable {
    struct Phase: Hashable, Sendable {
        var minutes: Double?
        var heat: HeatLevel?
    }

    var phases: [Phase] = []
    /// "needed 5 more minutes" (+5), "10 minutes less" (−10).
    var delta: Double?
    /// Numbers after "instead of" ("10 minutes instead of 30" → [30]): which duration to change.
    var oldNumbers: [Double] = []
    var cover: Bool?
    var skip = false
    /// "didn't marinate the chicken": skipped one action, which may not be the whole step.
    var skipByVerb = false
    /// Oven, air fryer, grill…: a different method the rules can't write.
    var method = false
    /// "added the onions before the spices", "added the garlic earlier".
    var order = false
    /// Cooking verbs in the clause (lemmas: "toast", "sauté", "cook").
    var verbs: [String] = []
    /// "step 7", "the third step" (0-based).
    var stepNumber: Int?

    var minutes: Double? { phases.count == 1 ? phases[0].minutes : nil }
    var heat: HeatLevel? { phases.count == 1 ? phases[0].heat : nil }
    var hasTime: Bool { phases.contains { $0.minutes != nil } || delta != nil }
    var hasHeat: Bool { phases.contains { $0.heat != nil } }
    var isEmpty: Bool { phases.isEmpty && delta == nil && cover == nil && !skip && !method && !order }
}

/// Rules for feedback about steps: time ("only 5 min", "10 minutes instead of 30", "needed 5 more
/// minutes", "5 min on high then 5 on low"), heat, covering, skipping a step, a different method
/// (oven) or order ("added the onions before the spices"). Finds the step the clause is about
/// (step number, the step's "Label:", ingredients, cooking verbs) and rewrites it where that is
/// safe; otherwise the change becomes a note tied to that step.
public struct StepFeedbackParser: Sendable {
    public let catalog: IngredientCatalog

    public init(catalog: IngredientCatalog = .shared) {
        self.catalog = catalog
    }

    // MARK: Vocabulary

    static let unitPattern = "hours?|hrs?|minutes?|mins?|seconds?|secs?"
    static var numberPattern: String { TimeEstimator.numberPattern }

    /// Heat phrases; one of groups 1–3 is the level.
    static let heatPhrase = "\\b(?:on|over|at|to)\\s+(?:a\\s+|the\\s+)?(?:very\\s+)?(\(HeatLevel.pattern))(?![\\w-])(?:\\s+(?:heat|flame|fire|setting|gas))?|\\b(\(HeatLevel.pattern))(?:\\s+|-)(?:heat|flame|fire)\\b|\\bheat\\s+(?:on|to|at)\\s+(\(HeatLevel.pattern))(?![\\w-])"

    /// Step text that changes the heat without naming a level ("Lower heat", "raise heat").
    static let heatChangeWords = "\\b(?:lower|raise|reduce|increase|turn (?:up|down)|crank up)\\s+(?:the\\s+)?(?:heat|flame)\\b|\\bturn (?:the )?(?:heat|flame) (?:up|down)\\b"

    /// (lemma, pattern) for cooking verbs, matched as whole words.
    static let verbs: [(lemma: String, pattern: String)] = [
        ("stir-fry", "stir[- ]?fr(?:y|ied|ies|ying)"),
        ("dry out", "dr(?:y|ied|ies|ying)(?: (?:it|them|the \\w+))? out"),
        ("toast", "toast(?:s|ed|ing)?"),
        ("grind", "grind(?:s|ing)?"),
        ("temper", "temper(?:s|ed|ing)?"),
        ("sauté", "saut[eé](?:s|e?d|ing)?"),
        ("fry", "(?<!stir[- ])(?<!stir)fr(?:y|ied|ies|ying)"),
        ("simmer", "simmer(?:s|ed|ing)?"),
        ("boil", "boil(?:s|ed|ing)?"),
        ("blanch", "blanch(?:es|ed|ing)?"),
        ("braise", "brais(?:e|es|ed|ing)"),
        ("marinate", "marinat(?:e|es|ed|ing)|marinade"),
        ("sear", "sear(?:s|ed|ing)?"),
        ("brown", "brown(?:s|ed|ing)?(?! sugar)"),
        ("roast", "roast(?:s|ed|ing)?"),
        ("bake", "bak(?:e|es|ed|ing)"),
        ("steam", "steam(?:s|ed|ing)?"),
        ("reduce", "reduc(?:e|es|ed|ing)(?! (?:the )?heat)"),
        ("rest", "rest(?:s|ed|ing)?(?! of)"),
        ("soak", "soak(?:s|ed|ing)?"),
        ("melt", "melt(?:s|ed|ing)?"),
        ("caramelise", "carameli[sz](?:e|es|ed|ing)"),
        ("grill", "grill(?:s|ed|ing)?"),
        ("poach", "poach(?:es|ed|ing)?"),
        ("cook", "cook(?:s|ed|ing)?"),
    ]

    /// Verbs that don't happen over heat; never the verb a time or heat change attaches to.
    static let coldVerbs: Set<String> = ["marinate", "rest", "soak", "grind"]

    static let methodPattern = "\\b(?:in|into|using|with)\\s+(?:the|an|a|my)\\s+(?:oven|air[- ]?fryer|instant pot|pressure cooker|slow cooker|rice cooker|microwave|grill|broiler)\\b|\\b(?:baked|roasted|grilled|broiled|air[- ]?fried|pressure[- ]cooked|microwaved)\\b|\\d+\\s*(?:°|degrees)"

    static let orderPattern = "\\b(?:before|after|earlier|later|sooner|first|at the (?:end|start|beginning)|too (?:early|late|soon)|halfway|right away|at once|all together|together)\\b"

    static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth"]

    // MARK: Labels and sentences

    /// "Chicken" for "Chicken: Add chicken and coat well." (a short leading label, ≤ 4 words).
    public static func label(of step: String) -> String? {
        guard let m = Rx.firstMatch("^\\s*([A-Z][\\p{L}’'&/ -]{0,30}?):\\s+\\S", in: step, []), let label = m[1] else { return nil }
        return label.split(separator: " ").count <= 4 ? label : nil
    }

    /// The label prefix ("Chicken: ") and the rest.
    static func splitLabel(_ step: String) -> (prefix: String, body: String) {
        guard label(of: step) != nil, let m = Rx.firstMatch("^(\\s*[^:]+:\\s+)", in: step, []), let prefix = m[1] else { return ("", step) }
        return (prefix, String(step.dropFirst(prefix.count)))
    }

    /// Sentences with their trailing punctuation and spaces, so `joined()` gives the text back.
    /// Never splits inside parentheses or on a decimal point.
    static func sentences(_ text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var current = ""
        var depth = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            if c == "(" { depth += 1 } else if c == ")" { depth = max(0, depth - 1) }
            if depth == 0, ".!?".contains(c),
               !(c == "." && i > 0 && chars[i - 1].isNumber && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i + 1
                while j < chars.count, ".!?".contains(chars[j]) { current.append(chars[j]); j += 1 }
                while j < chars.count, chars[j].isWhitespace { current.append(chars[j]); j += 1 }
                out.append(current)
                current = ""
                i = j
                continue
            }
            i += 1
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func lemmas(in text: String) -> [String] {
        var out: [String] = []
        var masked = text
        for (lemma, pattern) in verbs where Rx.test("\\b(?:\(pattern))\\b", masked) {
            out.append(lemma)
            masked = Rx.replace("\\b(?:\(pattern))\\b", in: masked, with: " ")
        }
        return out
    }

    // MARK: Signal

    /// What `clause` says about cooking, or nil when it says nothing about steps.
    func signal(_ clause: String, recipe: Recipe) -> StepSignal? {
        let s = FeedbackParser.bare(clause)
        guard !s.isEmpty else { return nil }
        if Rx.test("^(?:didn't|did not|don't|do not|no) need(?:ed)?\\b|\\bno (?:more|extra) time\\b", s) { return nil }
        var sig = StepSignal()
        var rest = s
        sig.verbs = Self.lemmas(in: s)
        sig.stepNumber = Self.stepNumber(in: s)

        // Skipping a step: "skipped the toasting", "didn't marinate the chicken", "skipped step 8".
        if let m = Rx.firstMatch("^(?:skipped|skip|didn't do|did not do|left out|omitted|didn't bother with|cut out)\\s+(.+)$", in: s) {
            let object = m[1]!
            let stepWord = Rx.test("\\bstep\\b", object) || !Self.lemmas(in: object).isEmpty
                || recipe.steps.contains { step in Self.label(of: step).map { Self.containsLabel($0, in: object) } ?? false }
            guard stepWord else { return nil }
            // An ingredient named on its own is the ingredient rules' job ("skipped the cilantro").
            let startsWithVerb = !Self.lemmas(in: String(FeedbackParser.stripArticles(object).split(separator: " ").first ?? "")).isEmpty
            if !startsWithVerb, !Rx.test("\\bstep\\b", object),
               FeedbackParser(catalog: catalog).findIngredient(object, in: recipe) != nil { return nil }
            sig.skip = true
            sig.verbs = Self.lemmas(in: object)
            return sig
        }
        if let m = Rx.firstMatch("^(?:(?:didn't|did not) (?:have time|get|bother) to|had no time to|forgot to|didn't|did not|never)\\s+(\\w+(?: \\w+)?)", in: s),
           !Rx.test("^cover", m[1]!), !Self.lemmas(in: m[1]!).isEmpty {
            sig.skip = true
            sig.skipByVerb = true
            sig.verbs = Self.lemmas(in: m[1]!)
            return sig
        }

        // Covering.
        if Rx.test("\\b(?:uncovered|without (?:a |the )?lid|lid off|no lid|didn't cover|did not cover|never covered|left (?:it |the lid )?(?:off|uncovered)|open pan)\\b", s) {
            sig.cover = false
        } else if Rx.test("\\b(?:covered|with (?:a |the )?lid|lid on|put (?:a|the) lid on)\\b", s) {
            sig.cover = true
        }

        sig.method = Rx.test(Self.methodPattern, s)
        sig.order = Rx.test(Self.orderPattern, s)
            && Rx.test("\\b(?:added|add|put|threw|tossed|stirred|mixed|cooked|fried|sauteed|sautéed)\\b", s)

        // "instead of 30 (minutes)", "rather than on low": which duration or heat it replaces.
        if let m = Rx.firstMatch("\\s*,?\\s*\\b(?:instead of|rather than|versus|vs\\.?|not)\\s+(?:the\\s+)?(?:written\\s+|listed\\s+|recipe'?s?\\s+)?(.+)$", in: rest) {
            let old = m[1]!
            let numbers = Rx.matches("(?<![\\w.])(\\d+(?:\\.\\d+)?)(?![\\w.])", in: old).compactMap { $0[1].flatMap(Double.init) }
            if !numbers.isEmpty || Rx.test("\\b(?:\(HeatLevel.pattern))\\b", old) {
                sig.oldNumbers = numbers
                rest = String(rest.dropLast(m[0]!.count))
            }
        }

        // Extra or less time.
        let n = Self.numberPattern, u = Self.unitPattern
        let deltas: [(String, Double)] = [
            ("\\b(?:another|an extra|an additional|extra)\\s+(\(n))\\s*(\(u))\\b", 1),
            ("(?<![\\w/.])(\(n))\\s*(?:more|extra|additional|further)\\s*(\(u))\\b", 1),
            ("(?<![\\w/.])(\(n))\\s*(\(u))\\s+(?:longer|more|extra)\\b", 1),
            ("(?<![\\w/.])(\(n))\\s*(\(u))\\s+(?:less|shorter|fewer|sooner|earlier)\\b", -1),
            ("(?<![\\w/.])(\(n))\\s*(?:fewer|less)\\s*(\(u))\\b", -1),
        ]
        for (pattern, sign) in deltas {
            guard let m = Rx.firstMatch(pattern, in: rest), let value = TimeEstimator.parseNumber(m[1]!) else { continue }
            sig.delta = sign * Self.minutes(value, unit: m[2]!)
            rest = rest.replacingOccurrences(of: m[0]!, with: " ")
            break
        }

        // Absolute times and heat, in phases: "5 min on high, then 5 on low".
        let segments = Rx.replace("\\s*,?\\s*(?:and\\s+)?\\b(?:then|followed by|after that|afterwards)\\s+|\\s+and\\s+(?=(?:\\d|on\\s|over\\s|at\\s|low\\b|high\\b|medium\\b|another\\b))",
                                  in: rest, with: "\u{1}").split(separator: "\u{1}").map(String.init)
        var phases: [StepSignal.Phase] = []
        var bare: [Int: Double] = [:]
        for seg in segments {
            var phase = StepSignal.Phase()
            if let span = Self.durationSpans(in: seg).first { phase.minutes = span.upperMinutes }
            else if let m = Rx.firstMatch("(?<![\\w.°])(\\d+(?:\\.\\d+)?)(?!\\s*(?:°|degrees|%|x\\b|[\\w.]))", in: seg), let v = Double(m[1]!) {
                bare[phases.count] = v
            }
            phase.heat = Self.heatLevel(in: seg)
            if phase.minutes != nil || phase.heat != nil || bare[phases.count] != nil { phases.append(phase) }
        }
        // A bare number next to timed phases is in minutes ("…then 5 on low").
        if phases.contains(where: { $0.minutes != nil }) {
            for (i, v) in bare where phases[i].minutes == nil { phases[i].minutes = v }
        } else {
            phases.removeAll { $0.heat == nil }
            for i in phases.indices where bare[i] != nil { phases[i].minutes = nil }
        }
        sig.phases = phases
        return sig.isEmpty ? nil : sig
    }

    static func minutes(_ value: Double, unit: String) -> Double {
        let u = unit.lowercased()
        return u.hasPrefix("h") ? value * 60 : u.hasPrefix("s") ? value / 60 : value
    }

    static func heatLevel(in text: String) -> HeatLevel? {
        guard let m = Rx.firstMatch(heatPhrase, in: text) else { return nil }
        return (m[1] ?? m[2] ?? m[3]).flatMap(HeatLevel.parse)
    }

    static func stepNumber(in s: String) -> Int? {
        if let m = Rx.firstMatch("\\bstep\\s*#?(\\d+)\\b|\\b(\\d+)(?:st|nd|rd|th)\\s+step\\b", in: s), let n = Int(m[1] ?? m[2] ?? "") { return n - 1 }
        if let m = Rx.firstMatch("\\b(\(ordinals.joined(separator: "|"))|last)\\s+step\\b", in: s), let word = m[1] {
            return word == "last" ? -1 : ordinals.firstIndex(of: word)
        }
        return nil
    }

    static let plainWords: Set<String> = [
        "with", "from", "into", "until", "then", "that", "this", "them", "they", "only", "more", "less", "minute",
        "hour", "second", "flame", "heat", "high", "medium", "about", "after", "before", "instead", "needed",
        "added", "really", "little", "much", "very", "time", "longer", "shorter", "step", "while", "also", "just",
        "over", "under", "when", "once", "still", "some", "each", "well", "your", "have", "didn", "because", "since",
        "earlier", "later", "first", "rather", "half", "whole", "pan", "pot", "wok", "lid", "cover", "covered", "uncovered",
        "make", "sure", "everything", "remaining", "other", "ingredient", "skipped", "skip", "used", "next", "last",
    ]

    /// Longer words worth matching between a clause and a step, minus time, heat and verb words.
    static func contentWords(_ text: String) -> Set<String> {
        var masked = text.lowercased()
        for (_, pattern) in verbs { masked = Rx.replace("\\b(?:\(pattern))\\b", in: masked, with: " ") }
        return Set(IngredientCatalog.normalise(masked).split(separator: " ").map(String.init)
            .filter { $0.count >= 4 && !plainWords.contains($0) && $0.rangeOfCharacter(from: .decimalDigits) == nil })
    }

    static func containsLabel(_ label: String, in text: String) -> Bool {
        let words = IngredientCatalog.normalise(label).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }
        let padded = " " + IngredientCatalog.normalise(text) + " "
        return padded.contains(" " + words.joined(separator: " ") + " ")
    }

    // MARK: Target

    /// The step a clause is about, or nil when no step clearly stands out.
    func target(_ sig: StepSignal, clause: String, recipe: Recipe, links: StepIngredientLinker.Links) -> Int? {
        guard !recipe.steps.isEmpty else { return nil }
        if let n = sig.stepNumber {
            let index = n < 0 ? recipe.steps.count - 1 : n
            return recipe.steps.indices.contains(index) ? index : nil
        }
        let linker = StepIngredientLinker(catalog: catalog)
        let mentioned = linker.links(for: Recipe(title: "", ingredients: recipe.ingredients, steps: [clause])).steps.first ?? []
        var firstMention: [UUID: Int] = [:]
        for (i, ids) in links.steps.enumerated() { for id in ids where firstMention[id] == nil { firstMention[id] = i } }
        let lead = mentioned.first

        // Ingredient words are scored through the links instead.
        let ingredientWords = Set(recipe.ingredients.flatMap { IngredientCatalog.normalise($0.name).split(separator: " ").map(String.init) })
        let clauseWords = Self.contentWords(clause).subtracting(ingredientWords)
        let longest = recipe.steps.map { Self.mainSpans(in: $0).map(\.upperMinutes).max() ?? 0 }
        var scores: [Int] = []
        // Whether the clause names something in the step (label, ingredient, verb, word, old time);
        // having a time or a heat setting only breaks ties.
        var specific: [Bool] = []
        for (i, step) in recipe.steps.enumerated() {
            var score = 0, named = false
            if let label = Self.label(of: step), Self.containsLabel(label, in: clause) { score += 4; named = true }
            // Other things both name ("the vegetables", "the noodles"): 2, or 3 for two or more.
            let shared = clauseWords.intersection(Self.contentWords(step)).count
            if shared > 0 { score += min(3, shared + 1); named = true }
            // A different method (oven, grill) replaces the long cook.
            if sig.method, longest[i] > 0, longest[i] == longest.max() { score += 2 }
            let stepIDs = links.steps.indices.contains(i) ? links.steps[i] : []
            for id in mentioned where stepIDs.contains(id) {
                score += 2
                named = true
                if firstMention[id] == i { score += 1 }
                // Order changes are about where the first-named ingredient goes in.
                if sig.order, id == lead, firstMention[id] == i { score += 2 }
            }
            let stepVerbs = Self.lemmas(in: step)
            for verb in sig.verbs where stepVerbs.contains(verb) {
                score += verb == "cook" ? 1 : 3
                if verb != "cook" { named = true }
            }
            let isHeatStep = stepVerbs.contains { !Self.coldVerbs.contains($0) }
            let spans = Self.durationSpans(in: step)
            if sig.hasTime, spans.contains(where: { !$0.isExtra }) { score += 2 }
            if (sig.hasTime || sig.hasHeat || sig.cover != nil || sig.method), isHeatStep { score += 1 }
            if sig.hasHeat, Rx.test(Self.heatPhrase, step) { score += 1 }
            if sig.cover != nil, Rx.test("\\b(?:un)?cover|\\blid\\b", step) { score += 1 }
            if !sig.oldNumbers.isEmpty, spans.contains(where: { $0.matches(sig.oldNumbers) }) {
                score += 3
                named = true
            }
            scores.append(score)
            specific.append(named)
        }
        guard let best = scores.max(), best >= 3 else { return nil }
        let winners = scores.indices.filter { scores[$0] == best }
        return winners.count == 1 && specific[winners[0]] ? winners[0] : nil
    }

    // MARK: Change

    /// The step change a clause asks for, or nil when it isn't about a step or no step stands out.
    public func change(for clause: String, recipe: Recipe) -> StepChange? {
        change(for: clause, recipe: recipe, links: StepIngredientLinker(catalog: catalog).links(for: recipe))
    }

    func change(for clause: String, recipe: Recipe, links: StepIngredientLinker.Links) -> StepChange? {
        guard let sig = signal(clause, recipe: recipe),
              let index = target(sig, clause: clause, recipe: recipe, links: links) else { return nil }
        let tidy = Self.tidy(clause)
        let step = recipe.steps[index]
        let note = StepChange.Outcome.note(Self.noteText(tidy, step: step, index: index))
        if sig.skip {
            // Removing the step must not lose an ingredient only it mentions.
            let only = links.steps[index].filter { id in !links.steps.enumerated().contains { $0.offset != index && $0.element.contains(id) } }
            // "didn't marinate" in a step that also mixes things: only part of the step was skipped.
            let partial = sig.skipByVerb && Rx.test("\\b(?:mix|add|combine|whisk|pour|stir|put|place|toss|coat)\\b", step)
            let safe = only.isEmpty && recipe.steps.count > 1 && !partial
            // A partly skipped step is worth a rewrite; a whole one that can't go stays a note.
            return StepChange(stepIndex: index, outcome: safe ? .remove : note, clause: tidy, wantsModel: partial)
        }
        if sig.method || sig.order {
            return StepChange(stepIndex: index, outcome: note, clause: tidy, wantsModel: true)
        }
        let mentionNames = mentionedNames(clause, recipe: recipe)
        if let text = StepTextEditor.rewrite(step, sig, mentions: { sentence in
            mentionNames.contains { StepRewrites.occurrences(of: $0, in: sentence) > 0 }
        }), text != step {
            return StepChange(stepIndex: index, outcome: .rewrite(text), clause: tidy, wantsModel: false)
        }
        return StepChange(stepIndex: index, outcome: note, clause: tidy, wantsModel: true)
    }

    /// Names (with catalog aliases) of the recipe ingredients a clause mentions.
    func mentionedNames(_ clause: String, recipe: Recipe) -> [String] {
        let ids = StepIngredientLinker(catalog: catalog).links(for: Recipe(title: "", ingredients: recipe.ingredients, steps: [clause])).steps.first ?? []
        return recipe.ingredients.filter { ids.contains($0.id) }.flatMap { catalog.aliases(for: $0) }
    }

    /// "I only cooked it 5 min" → "I only cooked it 5 min" (whitespace collapsed, capitalised,
    /// no trailing punctuation).
    static func tidy(_ clause: String) -> String {
        let text = clause.collapsedWhitespace.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!"))
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// "Step 7 (Chicken): Did it in the oven at 200°C".
    static func noteText(_ clause: String, step: String, index: Int) -> String {
        "Step \(index + 1)\(label(of: step).map { " (\($0))" } ?? ""): \(clause)"
    }

    // MARK: Continuations

    /// A clause that only continues the previous one's timing: "5 minutes on low flame", "low for 5".
    static func isContinuation(_ clause: String) -> Bool {
        let s = FeedbackParser.bare(clause)
        let n = numberPattern, u = unitPattern
        return Rx.test("^(?:then\\s+|after that\\s+|followed by\\s+)?(?:for\\s+)?(?:another\\s+)?(?:(?:\(n))\\s*(?:\(u))?\\b|(?:on|over|at)\\s+(?:a\\s+)?(?:\(HeatLevel.pattern))\\b|(?:\(HeatLevel.pattern))\\b|covered\\b|uncovered\\b)", s)
            && !Rx.test("\\b(?:added|used|skipped|replaced|swapped|too|needed)\\b", s)
    }

    static func hasTimingOrHeat(_ clause: String) -> Bool {
        !durationSpans(in: clause).isEmpty || Rx.test(heatPhrase, clause)
    }

    /// Joins clauses that continue a timed one ("…on a high flame and" + "5 minutes on low flame").
    static func mergingContinuations(_ clauses: [String]) -> [String] {
        var out: [String] = []
        for clause in clauses {
            if let last = out.last, hasTimingOrHeat(last), isContinuation(clause) {
                let head = Rx.replace("\\s+and$", in: last, with: "")
                out[out.count - 1] = head + ", then " + Rx.replace("^(?:then|after that|followed by)\\s+", in: clause, with: "")
            } else {
                out.append(clause)
            }
        }
        return out
    }

    /// Joins a sentence like "Then 5 on low." to the timed sentence before it.
    static func mergingContinuedSentences(_ sentences: [String]) -> [String] {
        var out: [String] = []
        for sentence in sentences {
            if let last = out.last, hasTimingOrHeat(last), Rx.test("^(?:then|and then|after that|followed by)\\b", sentence),
               isContinuation(sentence) {
                let tail = Rx.replace("^(?:and then|then|after that|followed by)\\s+", in: sentence, with: "")
                out[out.count - 1] = last + ", then " + tail
            } else {
                out.append(sentence)
            }
        }
        return out
    }

    // MARK: Durations

    struct DurationSpan {
        var range: NSRange
        var text: String
        var lower: Double
        var upper: Double
        /// "h", "m" or "s".
        var unit: Character
        var isExtra: Bool

        var upperMinutes: Double { StepFeedbackParser.minutes(upper, unit: String(unit)) }

        func matches(_ numbers: [Double]) -> Bool {
            numbers.contains { abs($0 - lower) < 0.01 || abs($0 - upper) < 0.01 || abs($0 - upperMinutes) < 0.01 }
        }
    }

    /// Duration phrases with their positions ("25–35 min", "about 1 minute" → "1 minute").
    /// "10 more minutes" is flagged `isExtra`.
    static func durationSpans(in text: String) -> [DurationSpan] {
        let ns = text as NSString
        return Rx.re(TimeEstimator.durationPattern).matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let lower = TimeEstimator.parseNumber(ns.substring(with: m.range(at: 1))) else { return nil }
            let upper = m.range(at: 2).location != NSNotFound ? TimeEstimator.parseNumber(ns.substring(with: m.range(at: 2))) ?? lower : lower
            let unitText = ns.substring(with: m.range(at: 3)).lowercased()
            let unit: Character = unitText.hasPrefix("h") ? "h" : unitText.hasPrefix("s") ? "s" : "m"
            let whole = ns.substring(with: m.range)
            return DurationSpan(range: m.range, text: whole, lower: lower, upper: max(lower, upper), unit: unit,
                                isExtra: Rx.test("\\b(?:more|extra|additional|further)\\b", whole))
        }.filter { !$0.isExtra }
    }

    /// Spans not inside parentheses (parenthetical times are alternatives: "(boneless: ~15–20 min)").
    static func mainSpans(in text: String) -> [DurationSpan] {
        let parens = Rx.re("\\([^()]*\\)").matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
        return durationSpans(in: text).filter { span in !parens.contains { NSIntersectionRange($0, span.range).length > 0 } }
    }
}

/// Deterministic rewrites of one step for a time, heat or cover change. Only the sentence that
/// holds the timing changes; the rest of the step stays verbatim. Nil when it isn't safe.
enum StepTextEditor {
    static func rewrite(_ step: String, _ sig: StepSignal, mentions: (String) -> Bool) -> String? {
        let (prefix, body) = StepFeedbackParser.splitLabel(step)
        var parts = StepFeedbackParser.sentences(body)
        guard !parts.isEmpty else { return nil }
        var candidates = Array(parts.indices)
        let hasVerb: (Int) -> Bool = { heatVerb(in: parts[$0], before: nil) != nil }
        if sig.hasTime {
            let timed = candidates.filter { !StepFeedbackParser.mainSpans(in: parts[$0]).isEmpty }
            if !timed.isEmpty { candidates = timed }
            else if sig.delta != nil || sig.phases.count > 1 { return nil }
            else { candidates = candidates.filter(hasVerb) }
        } else if sig.hasHeat {
            let heated = candidates.filter { Rx.test(StepFeedbackParser.heatPhrase, parts[$0]) }
            candidates = heated.isEmpty ? candidates.filter(hasVerb) : heated
        } else if sig.cover != nil {
            let covered = candidates.filter { Rx.test("\\b(?:un)?cover|\\blid\\b", parts[$0]) }
            candidates = covered.isEmpty ? candidates.filter(hasVerb) : covered
        } else {
            return nil
        }
        func narrow(_ keep: (Int) -> Bool) {
            let kept = candidates.filter(keep)
            if !kept.isEmpty { candidates = kept }
        }
        if !sig.oldNumbers.isEmpty {
            narrow { StepFeedbackParser.mainSpans(in: parts[$0]).contains { $0.matches(sig.oldNumbers) } }
        }
        narrow { mentions(parts[$0]) }
        let specific = sig.verbs.filter { $0 != "cook" }
        if !specific.isEmpty { narrow { !Set(StepFeedbackParser.lemmas(in: parts[$0])).isDisjoint(with: specific) } }
        guard candidates.count == 1 else { return nil }
        let i = candidates[0]
        guard let new = rewriteSentence(parts[i], sig), new != parts[i] else { return nil }
        parts[i] = new
        return prefix + parts.joined()
    }

    static func rewriteSentence(_ sentence: String, _ sig: StepSignal) -> String? {
        let lead = String(sentence.prefix(while: \.isWhitespace))
        let trailing = String(String(sentence.reversed().prefix(while: \.isWhitespace)).reversed())
        let core = sentence.trimmingCharacters(in: .whitespaces)
        let result = sig.phases.count > 1 ? composePhases(core, sig) : adjust(core, sig)
        return result.map { lead + $0 + trailing }
    }

    // MARK: One phase

    static func adjust(_ sentence: String, _ sig: StepSignal) -> String? {
        var text = sentence
        if let minutes = sig.minutes {
            if let span = mainSpan(in: text, sig.oldNumbers) {
                text = replacing(span.range, in: text, with: format(minutes, like: span.text))
                text = removingTimedParentheticals(text)
            } else {
                guard let at = insertionPoint(in: text) else { return nil }
                text = inserting(" " + format(minutes, like: nil), into: text, at: at)
            }
        } else if let delta = sig.delta {
            guard let span = mainSpan(in: text, sig.oldNumbers), let shifted = shift(span, by: delta) else { return nil }
            text = replacing(span.range, in: text, with: shifted)
        }
        if let heat = sig.heat {
            if let range = heatLevelRange(in: text) {
                text = replacing(range, in: text, with: heat.rawValue)
            } else {
                guard !Rx.test(StepFeedbackParser.heatChangeWords, text), let at = insertionPoint(in: text) else { return nil }
                text = inserting(" on \(heat.rawValue)", into: text, at: at)
            }
        }
        if let cover = sig.cover {
            guard let covered = applyingCover(cover, to: text) else { return nil }
            text = covered
        }
        return text
    }

    /// "Cover and cook on low 25–35 min until tender" + (5 min, high), (5 min, low) →
    /// "Cook on high 5 min, then cover and cook on low 5 min until tender".
    static func composePhases(_ sentence: String, _ sig: StepSignal) -> String? {
        guard sig.phases.allSatisfy({ $0.minutes != nil }), let span = mainSpan(in: sentence, sig.oldNumbers),
              let verb = heatVerb(in: sentence, before: span.range.location) else { return nil }
        let ns = sentence as NSString
        var lead = ns.substring(to: verb.location)
        let verbText = ns.substring(with: verb)
        let middle = ns.substring(with: NSRange(location: verb.location + verb.length, length: span.range.location - verb.location - verb.length))
        let tail = ns.substring(from: span.range.location + span.range.length)

        var covered = false
        if Rx.test("^cover(?:ed)?(?: (?:it|the (?:pan|pot|wok|kadai|lid))| with a lid)?(?:,\\s*|\\s+and\\s+)$", lead) {
            covered = true
            lead = ""
        }
        guard !Rx.test(StepFeedbackParser.heatChangeWords, lead) else { return nil }

        var template = "on {L}"
        var originalHeat: HeatLevel?
        var rest = middle
        if let m = Rx.re(StepFeedbackParser.heatPhrase).firstMatch(in: middle, range: NSRange(location: 0, length: (middle as NSString).length)) {
            let phrase = (middle as NSString).substring(with: m.range)
            for g in 1...3 where m.range(at: g).location != NSNotFound {
                let level = (middle as NSString).substring(with: m.range(at: g))
                originalHeat = HeatLevel.parse(level)
                let local = NSRange(location: m.range(at: g).location - m.range.location, length: m.range(at: g).length)
                template = (phrase as NSString).replacingCharacters(in: local, with: "{L}")
            }
            if !Rx.test("^(?:on|over|at|to)\\b", template) { template = "on " + template }
            rest = (middle as NSString).replacingCharacters(in: m.range, with: " ")
        }
        var connector = ""
        if let m = Rx.firstMatch("\\s*\\b((?:for\\s+)?(?:about|around|approximately)?\\s*~?)\\s*$", in: rest), let c = m[1], !c.trimmed.isEmpty {
            connector = c.trimmed + " "
            rest = String(rest.dropLast(m[0]!.count))
        }
        let object = rest.collapsedWhitespace
        guard object.isEmpty || Rx.test("^[\\p{L} ]+$", object) else { return nil }

        let coverIndex: Int? = switch sig.cover {
        case false?: nil
        case true?: sig.phases.count - 1
        case nil: covered ? (sig.phases.lastIndex { $0.heat != nil && $0.heat == originalHeat } ?? sig.phases.count - 1) : nil
        }
        var pieces: [String] = []
        for (k, phase) in sig.phases.enumerated() {
            var piece = k == coverIndex ? "cover and " : ""
            piece += verbText.lowercased()
            if k == 0, !object.isEmpty { piece += " " + object }
            if let heat = phase.heat { piece += " " + template.replacingOccurrences(of: "{L}", with: heat.rawValue) }
            piece += " " + connector + format(phase.minutes!, like: span.text)
            pieces.append(piece)
        }
        var composed = pieces[0] + pieces.dropFirst().map { ", then " + $0 }.joined()
        if lead.isEmpty { composed = composed.prefix(1).uppercased() + composed.dropFirst() }
        return lead + composed + removingTimedParentheticals(tail)
    }

    // MARK: Helpers

    /// The duration to change: the one "instead of" names, else the first outside parentheses.
    static func mainSpan(in text: String, _ oldNumbers: [Double]) -> StepFeedbackParser.DurationSpan? {
        let spans = StepFeedbackParser.mainSpans(in: text)
        if !oldNumbers.isEmpty, let hit = spans.first(where: { $0.matches(oldNumbers) }) { return hit }
        return spans.first
    }

    /// The last over-the-heat verb before `limit` (or anywhere).
    static func heatVerb(in text: String, before limit: Int?) -> NSRange? {
        let ns = text as NSString
        var best: NSRange?
        for (lemma, pattern) in StepFeedbackParser.verbs where !StepFeedbackParser.coldVerbs.contains(lemma) && lemma != "dry out" {
            for m in Rx.re("\\b(?:\(pattern))\\b").matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let limit, m.range.location >= limit { continue }
                if best == nil || m.range.location > best!.location { best = m.range }
            }
        }
        return best
    }

    /// Where a new time or heat goes: right after the verb when a time, "until", or the end of
    /// the clause follows; before "until" otherwise. Nil when neither fits.
    static func insertionPoint(in text: String) -> Int? {
        let span = mainSpan(in: text, [])
        guard let verb = heatVerb(in: text, before: span?.range.location) else { return nil }
        let ns = text as NSString
        let end = verb.location + verb.length
        let after = ns.substring(from: end)
        if let span, span.range.location >= end, Rx.test("^\\s*(?:for\\s+)?(?:about\\s+)?~?$", ns.substring(with: NSRange(location: end, length: span.range.location - end))) {
            return end
        }
        if Rx.test("^\\s*(?:until\\b|[,.;]|$)", after) { return end }
        if let m = Rx.re("\\s+until\\b").firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)) {
            return end + m.range.location
        }
        return nil
    }

    static func heatLevelRange(in text: String) -> NSRange? {
        guard let m = Rx.re(StepFeedbackParser.heatPhrase).firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        return (1...3).map { m.range(at: $0) }.first { $0.location != NSNotFound }
    }

    static func applyingCover(_ cover: Bool, to text: String) -> String? {
        let leadPattern = "^cover(?:ed)?(?: (?:it|the (?:pan|pot|wok|kadai|lid))| with a lid)?(?:,\\s*|\\s+and\\s+)"
        if !cover {
            if let m = Rx.firstMatch(leadPattern, in: text) {
                var rest = String(text.dropFirst(m[0]!.count))
                rest = rest.prefix(1).uppercased() + rest.dropFirst()
                guard let verb = heatVerb(in: rest, before: nil), verb.location == 0 else { return nil }
                return inserting(" uncovered", into: rest, at: verb.length)
            }
            return Rx.test("\\bcover", text) ? nil : text
        }
        if Rx.test("\\buncover", text) { return nil }
        if Rx.test("\\bcover|\\blid\\b", text) { return text }
        guard let verb = heatVerb(in: text, before: nil) else { return nil }
        if verb.location == 0 {
            let rest = (text as NSString).substring(from: 0)
            return "Cover and " + rest.prefix(1).lowercased() + rest.dropFirst()
        }
        return inserting("cover and ", into: text, at: verb.location)
    }

    static func replacing(_ range: NSRange, in text: String, with new: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: new)
    }

    static func inserting(_ new: String, into text: String, at location: Int) -> String {
        (text as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: new)
    }

    /// Drops parentheticals that give another time ("(boneless: ~15–20 min)"): after the cook's
    /// own time they would contradict it.
    static func removingTimedParentheticals(_ text: String) -> String {
        var out = text
        for m in Rx.matches("\\s*\\([^()]*\\)", in: text) {
            guard let whole = m[0], !StepFeedbackParser.durationSpans(in: whole).isEmpty else { continue }
            out = out.replacingOccurrences(of: whole, with: "")
        }
        return out
    }

    // MARK: Formatting

    static func number(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.001 ? String(Int(value.rounded())) : QuantityFormatter.string(from: value)
    }

    /// `minutes` written in the style of `original` ("25–35 min" → "5 min", "1 minute" → "3 minutes").
    static func format(_ minutes: Double, like original: String?) -> String {
        let o = original?.lowercased() ?? "min"
        let long = Rx.test("\\b(?:minutes?|hours?|seconds?)\\b", o)
        let mins = Rx.test("\\bmins\\b", o)
        if minutes < 1 {
            let secs = number(minutes * 60)
            return long ? "\(secs) seconds" : "\(secs) sec"
        }
        if minutes >= 60, Rx.test("\\b(?:hours?|hrs?)\\b", o) {
            let h = Int(minutes) / 60, r = Int(minutes.rounded()) % 60
            if r == 0 { return long ? "\(h) hour\(h == 1 ? "" : "s")" : "\(h) hr" }
            return long ? "\(h) hour\(h == 1 ? "" : "s") \(r) minutes" : "\(h) hr \(r) min"
        }
        let n = number(minutes)
        if long { return "\(n) minute\(minutes == 1 ? "" : "s")" }
        return "\(n) \(mins ? "mins" : "min")"
    }

    /// "25–35 min" + 5 → "30–40 min". Nil when the result isn't positive.
    static func shift(_ span: StepFeedbackParser.DurationSpan, by delta: Double) -> String? {
        let n = StepFeedbackParser.numberPattern
        if span.unit == "m", delta == delta.rounded(),
           let m = Rx.firstMatch("^(\(n))(?:(\\s*(?:-|–|—|to|or)\\s*)(\(n)))?(\\s*-?\\s*)(\(StepFeedbackParser.unitPattern))$", in: span.text) {
            let lower = span.lower + delta, upper = span.upper + delta
            guard lower > 0 else { return nil }
            var unit = m[5]!
            if Rx.test("^minutes?$", unit) { unit = upper == 1 ? "minute" : "minutes" }
            let range = m[3] != nil ? number(lower) + m[2]! + number(upper) : number(upper)
            return range + m[4]! + unit
        }
        let total = span.upperMinutes + delta
        return total > 0 ? format(total, like: span.text) : nil
    }
}
