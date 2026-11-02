import Foundation

/// A note the rules made because they couldn't turn what was said into a change (or a rule's
/// own fallback, like "Use less salt" for salt with no amount). The app asks the cook to keep it
/// as a note or change the recipe instead, starting from the step or ingredient below.
public struct UnresolvedNote: Hashable, Sendable {
    /// The `.addNote` text in the proposed edits.
    public var note: String
    /// What the cook said.
    public var said: String
    /// The step it most likely concerns (pre-selected when choosing one).
    public var stepIndex: Int?
    /// The ingredient it most likely concerns.
    public var ingredientID: UUID?
    /// A step-attached note from the step rules ("Step 7 (Chicken): …").
    public var isStepNote: Bool

    public init(note: String, said: String, stepIndex: Int?, ingredientID: UUID?, isStepNote: Bool) {
        self.note = note
        self.said = said
        self.stepIndex = stepIndex
        self.ingredientID = ingredientID
        self.isStepNote = isStepNote
    }
}

extension StepChange {
    /// The same change, credited to the cook's own words (its note too) rather than the
    /// instruction the rules read it as.
    func said(_ clause: String, recipe: Recipe) -> StepChange {
        var copy = self
        copy.clause = StepFeedbackParser.tidy(clause)
        if case .note = outcome, recipe.steps.indices.contains(stepIndex) {
            copy.outcome = .note(StepFeedbackParser.noteText(copy.clause, step: recipe.steps[stepIndex], index: stepIndex))
        }
        return copy
    }
}

/// "Change recipe": whatever the form of a clause, read it as an instruction for the recipe.
/// Past tense ("used 2 tbsp oil", "I cooked the chicken 10 min on high", "didn't use cilantro"),
/// statements ("2 tbsp oil is enough", "the chicken only needs 10 minutes", "it doesn't need the
/// dry-out step") and questions ("can we cook the chicken on high?") become the imperatives the
/// rules already understand ("use 2 tbsp oil", "cook the chicken 10 minutes", "skip the dry-out
/// step", "cook the chicken on high"). This is the one place that knows about phrasing; the
/// ingredient and step rules are shared with "I made this".
public enum ChangeIntent {
    /// The clause as an instruction: lowercased and bare (see `FeedbackParser.bare`). Text that
    /// matches no pattern is returned bare, so the rules see it exactly as before.
    public static func instruction(_ clause: String) -> String {
        var s = FeedbackParser.bare(clause.trimmingCharacters(in: CharacterSet(charactersIn: " ?.!")))
        for _ in 0..<2 {
            s = Rx.replace(questionLead, in: s, with: "")
            s = Rx.replace("^(?:only|just|actually|usually|always|really|also|then|honestly|definitely|probably)\\s+", in: s, with: "")
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,?"))
        for rule in rules {
            guard let m = Rx.firstMatch(rule.pattern, in: s), let out = rule.rewrite(m) else { continue }
            s = out.collapsedWhitespace
            break
        }
        return Self.basePastTense(s)
    }

    /// Questions, suggestions and hedges in front of an instruction.
    static let questionLead = "^(?:(?:can|could|shall|should|would|may|might) (?:we|i|you|it)(?: (?:please|maybe|just))?|why not|what if (?:we|i|you)|how about(?: (?:we|i|you))?|maybe(?: (?:we|i|you) (?:could|should|can))?|perhaps(?: (?:we|i|you) (?:could|should|can))?|let me|(?:i|we) (?:think|guess|reckon|feel)(?: (?:we|you|i|it) (?:should|could|can|would))?|(?:i|we)'?d(?: rather| prefer to| like to| just| probably)?|(?:i|we) would(?: rather| prefer to| like to)?|(?:i|we)'?ll(?: just)?|it(?:'d| would) be (?:better|nicer|good) to|better to|(?:i|we|you) (?:need|have|ought) to|need to|it'?s better to|i prefer to|i want to|i'd want to|(?:i|we) like to|(?:i|we) usually|(?:i|we) always|(?:i|we) normally|i|we)\\s+"

    /// "[2 tbsp oil] is enough": what was said, read as an instruction. Amounts become "use …";
    /// "less/more/half …" stay as they are.
    static func amountOrScale(_ text: String) -> String? {
        let t = FeedbackParser.stripArticles(text)
        if Rx.test("^(?:less|more|extra|half|double|a (?:bit|little|touch) (?:less|more))\\b", t) { return t }
        if Rx.test("^(?:\\d|[½¼¾⅓⅔⅛]|a |an |one |two |three |four |five |six )", t) || Rx.test("^(?:\\d|[½¼¾⅓⅔⅛])", text) { return "use " + text }
        return nil
    }

    static let subject = "(it|this|that|the recipe|the dish|you|we|.+?)"
    static let pronoun = "^(?:it|this|that|the recipe|the dish|you|we)$"
    static let modal = "(?:should|can|could|must|needs? to|has to|have to|ought to|is to|are to|would|will|only needs? to|just needs? to)"

    struct Rule: Sendable {
        var pattern: String
        var rewrite: @Sendable ([String?]) -> String?
    }

    static let rules: [Rule] = [
        // "no need to marinate", "it doesn't need to rest" → "don't marinate".
        Rule(pattern: "^(?:there'?s |there is )?no need to (.+)$") { "don't " + $0[1]! },
        Rule(pattern: "^(?:\(subject) )?(?:doesn't|does not|don't|do not|didn't|did not|won't) (?:really |even )?need(?:s|ed)? to (.+)$") { "don't " + $0[2]! },
        // "no need for the dry-out step", "it doesn't need cilantro" → "skip …" (a step or an ingredient).
        Rule(pattern: "^(?:there'?s |there is )?no need for (.+)$") { "skip " + $0[1]! },
        Rule(pattern: "^(?:\(subject) )?(?:doesn't|does not|don't|do not|didn't|did not|won't) (?:really |even )?need(?:s|ed)? (?!more\\b|less\\b|as\\b)(.+)$") { m in
            guard StepFeedbackParser.durationSpans(in: m[2]!).isEmpty else { return nil }
            return "skip " + m[2]!
        },
        // "the dry-out step isn't needed", "cilantro is unnecessary", "the cilantro can go".
        Rule(pattern: "^(.+?) (?:isn't|is not|aren't|are not|wasn't|was not|weren't|were not) (?:really )?(?:needed|necessary|required)$") { "skip " + $0[1]! },
        Rule(pattern: "^(.+?) (?:is|are|was|were|seems?|seemed) (?:unnecessary|pointless|not needed|optional|overkill)$") { "skip " + $0[1]! },
        Rule(pattern: "^(.+?) (?:can|could|should) (?:go|be (?:skipped|left out|dropped|removed|omitted|cut))$") { "skip " + $0[1]! },
        // "the oil is too much" → "less oil"; "the garlic isn't enough" → "more garlic".
        Rule(pattern: "^(.+?) (?:is|are|was|were|felt like|seems?|seemed) (?:way |a bit |a little |slightly |far )?too much$") { "less " + FeedbackParser.stripArticles($0[1]!) },
        Rule(pattern: "^(.+?) (?:isn't|is not|aren't|are not|wasn't|was not|weren't|were not) enough$") { "more " + FeedbackParser.stripArticles($0[1]!) },
        // "prawns work better than chicken" → "use prawns instead of chicken".
        Rule(pattern: "^(.+?) (?:works?|worked|is|are|was|were|tastes?|tasted|goes|went) (?:much |way |a lot )?better than (.+)$") { "use \($0[1]!) instead of \($0[2]!)" },
        // "it's better without cilantro" → "without cilantro"; "better with more garlic" → "more garlic".
        Rule(pattern: "^(?:(?:\(subject)) (?:is|are|was|were|tastes?|tasted|works?|worked) )?(?:much |way |a lot )?(?:better|nicer|best) (without|with) (.+)$") { m in
            m[2]! == "without" ? "without " + m[3]! : (amountOrScale(m[3]!) ?? "add " + m[3]!)
        },
        // "2 tbsp oil is enough", "half the sugar is plenty", "less oil is better".
        Rule(pattern: "^(.+?) (?:is|are|was|were|'s|would be|will be|should be) (?:plenty|enough|fine|sufficient|ok|okay|good|better|great|right|perfect|all (?:it|you) needs?|all that'?s needed)(?: for (?:it|this|me|us))?$") { amountOrScale($0[1]!) },
        // "the oil should be 2 tbsp" → "change the oil to 2 tbsp"; "the chicken should be cooked on high" → "cook the chicken on high".
        Rule(pattern: "^(.+?) \(modal) (?:only |just |really |probably )?be (\\S+)(.*)$") { m in
            let word = m[2]!, rest = m[3]!
            if let verb = baseVerb(word), word != verb || pastParticiples.contains(word) {
                return Rx.test(pronoun, m[1]!) ? "\(verb) it\(rest)" : "\(verb) \(m[1]!)\(rest)"
            }
            // Only an amount: "the oil should be fine" is not a change.
            guard !Rx.test(pronoun, m[1]!), Rx.test("^(?:\\d|[½¼¾⅓⅔⅛])", word) else { return nil }
            return "change \(m[1]!) to \(word)\(rest)"
        },
        // "the chicken should cook 10 min on high", "the sauce needs to simmer 5 min longer".
        Rule(pattern: "^(.+?) \(modal) (?:only |just |really |probably |also )?(\\w+(?:[- ]fry)?)(.*)$") { m in
            guard let verb = baseVerb(m[2]!) ?? (StepFeedbackParser.lemmas(in: m[2]!).isEmpty ? nil : m[2]!) else { return nil }
            return Rx.test(pronoun, m[1]!) ? "\(verb)\(m[3]!)" : "\(verb) \(m[1]!)\(m[3]!)"
        },
        // "the chicken only needs 10 minutes" → "cook the chicken 10 minutes"; "it needs 2 tbsp oil"
        // → "use 2 tbsp oil"; "the oil only needs 2 tbsp" → "change the oil to 2 tbsp".
        Rule(pattern: "^(.+?) (?:only |just |really )?(?:needs|need|needed|takes|take|took|requires|required|wants) (?:only |just |about |around |roughly )?(.+)$") { m in
            let who = m[1]!, what = m[2]!
            if !StepFeedbackParser.durationSpans(in: what).isEmpty {
                return Rx.test(pronoun, who) ? "cook " + what : "cook \(who) \(what)"
            }
            guard Rx.test("^(?:\\d|[½¼¾⅓⅔⅛])", what) else { return nil }
            if Rx.test(pronoun, who) { return "use " + what }
            // "2 tbsp" alone is an amount of the subject; "2 tbsp oil" names its own ingredient.
            let parsed = IngredientLineParser.parse(what)
            return parsed.name.isEmpty ? "change \(who) to \(what)" : "use " + what
        },
        // "the chicken was cooked 10 min on high" (passive report).
        Rule(pattern: "^(.+?) (?:was|were|got|is|are) (?:only |just )?(\\w+ed|fried|done|left out|cut)(?: (.*))?$") { m in
            let word = m[2]!
            if word == "left out" { return "leave out " + m[1]! }
            guard let verb = baseVerb(word), verb != "do" || m[3] != nil else { return nil }
            // A taste or texture ("it was overcooked", "the oil was heated") without anything to do stays as is.
            guard let rest = m[3], !rest.isEmpty || !StepFeedbackParser.lemmas(in: verb).isEmpty else { return nil }
            return Rx.test(pronoun, m[1]!) ? "\(verb == "do" ? "cook" : verb) it \(rest)" : "\(verb == "do" ? "cook" : verb) \(m[1]!) \(rest)"
        },
    ]

    /// Past participles that are also adjectives ("the oil should be fine" is not a verb).
    static let pastParticiples: Set<String> = ["cooked", "fried", "simmered", "baked", "roasted", "marinated", "covered",
                                               "uncovered", "added", "used", "skipped", "removed", "left", "cut", "halved",
                                               "doubled", "reduced", "toasted", "seared", "steamed", "boiled", "grilled", "done"]

    /// Leading past tense → base ("used 2 tbsp oil" → "use 2 tbsp oil"); the rest is unchanged.
    static func basePastTense(_ s: String) -> String {
        if let m = Rx.firstMatch("^(?:didn't|did not|never)\\s+(.+)$", in: s) { return "don't " + m[1]! }
        if let m = Rx.firstMatch("^stir[- ]?fried\\b(.*)$", in: s) { return "stir-fry" + m[1]! }
        guard let m = Rx.firstMatch("^(\\w+)\\b(.*)$", in: s), let first = m[1], let verb = irregular[first] ?? regularBase(first) else { return s }
        return verb + m[2]!
    }

    /// A verb's base form for a past form (or the base itself for known verbs). Nil otherwise.
    static func baseVerb(_ word: String) -> String? {
        if word == "done" { return "do" }
        if let v = irregular[word] ?? regularBase(word) { return v }
        return knownVerbs.contains(word) ? word : nil
    }

    static let irregular: [String: String] = [
        "used": "use", "added": "add", "cooked": "cook", "skipped": "skip", "left": "leave", "omitted": "omit",
        "replaced": "replace", "swapped": "swap", "switched": "switch", "subbed": "sub", "substituted": "substitute",
        "removed": "remove", "dropped": "drop", "threw": "throw", "thrown": "throw", "tossed": "toss", "stirred": "stir",
        "topped": "top", "finished": "finish", "garnished": "garnish", "reduced": "reduce", "increased": "increase",
        "halved": "halve", "doubled": "double", "simmered": "simmer", "fried": "fry", "baked": "bake",
        "marinated": "marinate", "covered": "cover", "uncovered": "uncover", "went": "go", "toasted": "toast",
        "sauteed": "sauté", "sautéed": "sauté", "boiled": "boil", "roasted": "roast", "grilled": "grill",
        "steamed": "steam", "rested": "rest", "soaked": "soak", "browned": "brown", "seared": "sear",
        "upped": "up", "bumped": "bump", "lowered": "lower", "raised": "raise", "changed": "change", "made": "make",
        "gave": "give", "kept": "keep", "put": "put", "cut": "cut", "tried": "try", "ditched": "ditch",
        "poached": "poach", "blanched": "blanch", "braised": "braise", "melted": "melt", "ground": "grind",
        "tempered": "temper", "mixed": "mix", "whisked": "whisk", "combined": "combine", "poured": "pour",
        "chopped": "chop", "sliced": "slice", "minced": "mince", "diced": "dice", "heated": "heat",
    ]

    static let knownVerbs: Set<String> = Set(irregular.values).union(["stir-fry", "caramelise", "caramelize", "season", "salt"])

    /// "simmered" → "simmer" only for verbs in `irregular`'s values (no guessing at other words).
    static func regularBase(_ word: String) -> String? {
        guard word.hasSuffix("ed") else { return nil }
        let stem = String(word.dropLast(2))
        for candidate in [stem, stem + "e", String(stem.dropLast())] where knownVerbs.contains(candidate) { return candidate }
        return nil
    }
}
