import Foundation

/// Rule-based feedback → edits. Used directly when the on-device model is unavailable,
/// and as hints for the model when it is.
public struct FeedbackParser: Sendable {
    public let catalog: IngredientCatalog
    /// A report of a cook ("I made this") or instructions for the recipe ("Change recipe"). In
    /// `.change` every clause is first read as an instruction (`ChangeIntent`), whatever its tense
    /// or form, and notes don't say "than last time".
    public var kind: FeedbackKind

    public init(catalog: IngredientCatalog = .shared, kind: FeedbackKind = .cooked) {
        self.catalog = catalog
        self.kind = kind
    }

    public static func edits(from feedback: String, recipe: Recipe, kind: FeedbackKind = .cooked,
                             catalog: IngredientCatalog = .shared) -> [RecipeEdit] {
        FeedbackParser(catalog: catalog, kind: kind).edits(from: feedback, recipe: recipe)
    }

    /// Words that start a new clause after "and" / "but" / "so".
    /// Imperatives count too ("…and cook the chicken on high", "…and skip step 8").
    static let clauseStarters = "it|i|we|they|that|this|was|were|needed|need|used|use|added|add|skipped|skip|left|leave|omitted|omit|replaced|replace|subbed|substituted|substitute|swapped|swap|switch|remove|threw|tossed|cooked|cook|baked|bake|simmered|simmer|fry|stir[- ]?fry|marinate|took|too|less|more|cut|doubled|double|halved|halve|didn't|did not|don't|do not|no|not|next|make|the (?:\\w+ )?(?:was|were|needed)"

    /// Clauses that carry no information; dropped rather than kept as notes.
    static let filler = "^(?:no (?:changes?|problems?|issues?|complaints?)|nothing(?: else)?|none|n/?a|ok(?:ay)?|that'?s it|thanks?|(?:it was |it's |was )?(?:so |really |very |just )?(?:perfect|delicious|great|good|tasty|lovely|amazing|excellent|yum(?:my)?|just right|spot on)(?: as is)?)$"

    static func isFiller(_ clause: String) -> Bool {
        Rx.test(filler, bare(clause)) || Rx.test(filler, clause.lowercased().collapsedWhitespace)
    }

    /// The outcome of parsing one clause. `consumed` means the clause was understood (even if it
    /// produced no edit, like "not too salty"); `leftover` is unrelated text to keep as a note.
    struct ClauseResult {
        var edits: [RecipeEdit] = []
        var consumed = false
        var leftover: String?
        /// "make it serve 6": understood, but not a change the recipe can save.
        var servings: Int?

        static let unmatched = ClauseResult()
        static func of(_ edits: [RecipeEdit]) -> ClauseResult { ClauseResult(edits: edits, consumed: !edits.isEmpty) }
    }

    public func edits(from feedback: String, recipe: Recipe) -> [RecipeEdit] {
        analyse(feedback, recipe: recipe).edits
    }

    /// Feedback split into ingredient edits and notes, and step changes.
    public struct Analysis: Hashable, Sendable {
        /// Ingredient edits and notes first, then the step changes' edits (rewrites, removals,
        /// step-attached notes).
        public var edits: [RecipeEdit]
        public var stepChanges: [StepChange]
        /// The feedback without the clauses that became step changes ("" when all did).
        public var otherFeedback: String
        /// "make it serve 6": the servings asked for. Not an edit: servings scale on the recipe
        /// screen, and no edit kind stores them.
        public var servings: Int? = nil
        /// Notes (in `edits`) the rules made because they couldn't turn what was said into a
        /// change: the app asks whether to keep each as a note or change the recipe instead.
        public var unresolved: [UnresolvedNote] = []
        /// Notes the cook asked for ("note: …", "remember that …"): always notes.
        public var explicitNotes: [String] = []

        /// The unresolved note behind a `.addNote` edit, if it is one.
        public func unresolved(for edit: RecipeEdit) -> UnresolvedNote? {
            guard case let .addNote(text) = edit else { return nil }
            return unresolved.first { $0.note == text }
        }
    }

    public func analyse(_ feedback: String, recipe: Recipe) -> Analysis {
        let steps = StepFeedbackParser(catalog: catalog)
        let links = StepIngredientLinker(catalog: catalog).links(for: recipe)
        var stepChanges: [StepChange] = []
        var other: [String] = []
        var edits: [RecipeEdit] = []
        var servings: Int?
        var unresolved: [UnresolvedNote] = []
        var explicit: [String] = []
        func addUnresolved(_ note: String, said: String) {
            guard !unresolved.contains(where: { $0.note == note }) else { return }
            unresolved.append(unresolvedNote(note, said: said, recipe: recipe, links: links))
        }
        for sentence in StepFeedbackParser.mergingContinuedSentences(Self.sentences(feedback)) {
            // "note: …", "remember that …": kept as written, never parsed.
            if let note = Self.explicitNote(in: sentence) {
                if !edits.contains(.addNote(note)) { edits.append(.addNote(note)) }
                explicit.append(note)
                continue
            }
            var unmatched: [String] = []
            var kept: [String] = []
            for clause in StepFeedbackParser.mergingContinuations(Self.clauses(sentence)) {
                // "Change recipe": the clause is read as an instruction first ("used 2 tbsp oil",
                // "2 tbsp oil is enough", "can we…?" → "use 2 tbsp oil"); the rules then read it as usual.
                let text = kind == .change ? ChangeIntent.instruction(clause) : clause
                // Steps first: "cooked the chicken 5 min on high" is about step 7, not the chicken.
                if var change = steps.change(for: text, recipe: recipe, links: links) {
                    if text != clause { change = change.said(clause, recipe: recipe) }
                    add(change, text: text, to: &stepChanges, recipe: recipe)
                    if case let .note(note) = change.outcome, !unresolved.contains(where: { $0.note == note }) {
                        unresolved.append(UnresolvedNote(note: note, said: change.clause, stepIndex: change.stepIndex,
                                                         ingredientID: nil, isStepNote: true))
                    }
                    continue
                }
                let result = parse(clause: text, recipe: recipe)
                if let n = result.servings {
                    servings = n
                    continue
                }
                kept.append(clause)
                if !result.consumed {
                    if !Self.isFiller(clause) { unmatched.append(clause) }
                    continue
                }
                for e in result.edits where !edits.contains(e) {
                    edits.append(e)
                    // A rule's own note ("Use less salt" with no salt amount) is a fallback, not a change.
                    if case let .addNote(note) = e { addUnresolved(note, said: StepFeedbackParser.tidy(clause)) }
                }
                if let leftover = result.leftover, !Rx.test(Self.filler, leftover) { unmatched.append(leftover) }
            }
            if !unmatched.isEmpty {
                // Feedback is never lost: whatever the rules didn't understand is kept as a note. A
                // report keeps one note per sentence; instructions one per clause, so each can become
                // its own change.
                for group in kind == .change ? unmatched.map({ [$0] }) : [unmatched] {
                    let text = group.joined(separator: ", ")
                    var note = text.prefix(1).uppercased() + text.dropFirst()
                    if kind == .change { note = StepFeedbackParser.tidy(note) }
                    if !edits.contains(.addNote(note)) { edits.append(.addNote(note)) }
                    addUnresolved(note, said: note)
                }
            }
            if !kept.isEmpty { other.append(kept.joined(separator: ", ")) }
        }
        var all = Self.resolvingConflicts(edits)
        for change in stepChanges where !all.contains(change.edit) { all.append(change.edit) }
        // Only notes still in the edits, and never one the cook asked for.
        unresolved.removeAll { u in !all.contains(.addNote(u.note)) || explicit.contains(u.note) }
        return Analysis(edits: all, stepChanges: stepChanges, otherFeedback: other.joined(separator: ". "), servings: servings,
                        unresolved: unresolved, explicitNotes: explicit)
    }

    /// An unresolved note with the step and ingredient it most likely concerns.
    public func unresolvedNote(_ note: String, said: String, recipe: Recipe) -> UnresolvedNote {
        unresolvedNote(note, said: said, recipe: recipe, links: StepIngredientLinker(catalog: catalog).links(for: recipe))
    }

    func unresolvedNote(_ note: String, said: String, recipe: Recipe, links: StepIngredientLinker.Links) -> UnresolvedNote {
        let text = kind == .change ? ChangeIntent.instruction(said) : said
        // What was said names it, or the rule's note does ("Use less salt" for "too salty").
        let mentioned = StepIngredientLinker(catalog: catalog)
            .links(for: Recipe(title: "", ingredients: recipe.ingredients, steps: [said, note])).steps.flatMap { $0 }
        let ingredient = recipe.ingredients.first { mentioned.contains($0.id) }?.id
            ?? findIngredient(Rx.replace("^\\w+\\s+", in: Self.bare(text), with: ""), in: recipe)?.id
        return UnresolvedNote(note: note, said: said,
                              stepIndex: StepFeedbackParser(catalog: catalog).likelyStep(for: text, recipe: recipe, links: links),
                              ingredientID: ingredient, isStepNote: false)
    }

    /// "note: serve with rice", "add a note: …", "remember that it's better the next day" → the
    /// note's text. Nil for anything else ("remember to add salt" is an instruction).
    static func explicitNote(in sentence: String) -> String? {
        let s = sentence.replacingOccurrences(of: "’", with: "'").collapsedWhitespace
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!"))
        let patterns = [
            "^(?:please\\s+)?(?:note|nb|n\\.b\\.|tip|reminder|note to self|for the notes?)\\s*[:–—-]\\s*(.+)$",
            "^(?:please\\s+)?(?:can you\\s+|could you\\s+)?(?:add|make|save|keep|leave|write|put)(?: (?:it|this))?(?: down)?(?: as)? (?:a |the )?note(?: (?:that|saying|to say|about))?\\s*[:,–—-]?\\s+(.+)$",
            "^(?:just\\s+)?(?:remember|keep in mind|bear in mind|worth noting|note)\\s+that\\s+(.+)$",
        ]
        for pattern in patterns {
            guard let m = Rx.firstMatch(pattern, in: s), let body = m[1]?.trimmed, !body.isEmpty else { continue }
            return body.prefix(1).uppercased() + body.dropFirst()
        }
        return nil
    }

    /// A second change to a step already rewritten builds on the rewrite; otherwise both are kept
    /// (a removal wins over a rewrite of the same step). `text` is the clause as the rules read it.
    func add(_ change: StepChange, text: String? = nil, to changes: inout [StepChange], recipe: Recipe) {
        guard let i = changes.firstIndex(where: { $0.stepIndex == change.stepIndex }) else {
            changes.append(change)
            return
        }
        let previous = changes[i]
        switch (previous.outcome, change.outcome) {
        case (.remove, _):
            return
        case (_, .remove):
            changes[i] = change
        case let (.rewrite(rewrite), _):
            var rewritten = recipe
            rewritten.steps[change.stepIndex] = rewrite
            if let again = StepFeedbackParser(catalog: catalog).change(for: text ?? change.clause, recipe: rewritten), case .rewrite = again.outcome {
                changes[i] = StepChange(stepIndex: change.stepIndex, outcome: again.outcome,
                                        clause: previous.clause + "; " + change.clause, wantsModel: false)
            } else {
                changes.append(change)
            }
        default:
            changes.append(change)
        }
    }

    /// An explicit replace or remove beats a scale of the same ingredient ("too salty" + "used
    /// light soy sauce instead of dark" shouldn't also shrink the dark soy sauce), and only the
    /// first scale per ingredient is kept.
    static func resolvingConflicts(_ edits: [RecipeEdit]) -> [RecipeEdit] {
        var replaced: Set<UUID> = []
        for edit in edits {
            switch edit {
            case .replaceIngredient(let id, _, _), .removeIngredient(let id): replaced.insert(id)
            default: break
            }
        }
        var scaled: Set<UUID> = []
        return edits.filter { edit in
            guard case .scaleIngredient(let id, _) = edit else { return true }
            if replaced.contains(id) || scaled.contains(id) { return false }
            scaled.insert(id)
            return true
        }
    }

    /// Splits on . ! ? ; and newlines, but not on a decimal point ("1.5 tbsp").
    static func sentences(_ text: String) -> [String] {
        Rx.replace("[!?;\\n]|(?<!\\d)\\.|\\.(?!\\d)", in: text, with: "\u{1}")
            .split(separator: "\u{1}")
            .map { String($0).collapsedWhitespace }
            .filter { !$0.isEmpty }
    }

    static func clauses(_ sentence: String) -> [String] {
        var s = sentence
        // Mark boundaries: commas, and "and/but/so/then" when a new clause follows.
        s = Rx.replace("\\s*,\\s*(?:and|but|so|then)?\\s+", in: s, with: "\u{1}")
        s = Rx.replace("\\s+(?:but|then|although|though|because)\\s+", in: s, with: "\u{1}")
        // "and" / "so" only when a new clause follows ("…so I used a pot", not "it was so good").
        s = Rx.replace("\\s+(?:and|so)\\s+(?=(?:\(clauseStarters))\\b)", in: s, with: "\u{1}")
        return s.split(separator: "\u{1}").map { String($0).collapsedWhitespace }.filter { !$0.isEmpty }
    }

    /// Lowercased, without leading "I " / "we " / "it was" and trailing "next time" etc.
    static func bare(_ clause: String) -> String {
        var s = clause.lowercased().replacingOccurrences(of: "’", with: "'").collapsedWhitespace
        s = Rx.replace("^(?:i|we|also|then|but|and|so|just)\\s+", in: s, with: "")
        // Instructions: "please use less salt", "next time, cook it on high", "I'd like to skip step 8".
        for _ in 0..<2 { s = Rx.replace(instructionLead, in: s, with: "") }
        s = Rx.replace("^(?:i|we)\\s+", in: s, with: "")
        s = Rx.replace("\\s+(?:next time|this time|than (?:written|the recipe said|listed)|in it|overall|though|too)$", in: s, with: "")
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " ,:"))
    }

    /// Words that only make a clause an instruction ("please", "next time", "I'd like to").
    static let instructionLead = "^(?:please|pls|let's|lets|always|try(?: to)?|next time,?|from now on,?|in (?:the )?future,?|going forward,?|(?:i|we)(?:'d| would) (?:like|prefer|rather) to|(?:i|we) want to|(?:i|we|you) should|(?:i|we)'ll|(?:i|we) will|(?:i|we)'m going to|can you|could you|make sure (?:to|you|i)|remember to|want to)\\s+"

    // MARK: Patterns

    func parse(clause: String, recipe: Recipe) -> ClauseResult {
        let s = Self.bare(clause)
        guard !s.isEmpty else { return .unmatched }

        // Time: "needed 10 more minutes", "cooked it 5 extra minutes", "needed more time". (No step
        // was found. A report becomes a note about the cook; an instruction stays in its own words.)
        if kind == .change, Rx.test("\\b(?:more|extra|additional|further|another|longer)\\b.*\\b(?:min|minutes|mins|time)\\b|^(?:it\\s+)?(?:needs?|takes?|cook it|cook) (?:a bit |a little |a lot |much )?(?:more|longer)(?:\\s+time)?$", s) {
            return .unmatched
        }
        if let m = Rx.firstMatch("(\\d+)\\s*(?:more|extra|additional|further)\\s*(?:min|minutes|mins)\\b", in: s)
            ?? Rx.firstMatch("(?:another|an extra|an additional|extra)\\s+(\\d+)\\s*(?:min|minutes|mins)\\b", in: s) {
            return .of([.addNote("Needed about \(m[1]!) more minutes than written")])
        }
        if Rx.test("^(?:it\\s+)?(?:needed|took|needs)\\s+(?:a bit |a little |a lot |much )?(?:more|longer)(?:\\s+time)?$", s) {
            return .of([.addNote("Needed more time than written")])
        }

        // Replacements.
        if let m = Rx.firstMatch("^(?:used|use|tried|went with|go with|had to use)\\s+(.+?)\\s+(?:instead of|in place of|rather than)\\s+(.+)$", in: s)
            ?? Rx.firstMatch("^(.+?)\\s+instead of\\s+(.+)$", in: s) {
            return .of(replacement(new: m[1]!, old: m[2]!, recipe: recipe))
        }
        if let m = Rx.firstMatch("^(?:replaced|replace)\\s+(.+?)\\s+(?:with|for|by)\\s+(.+)$", in: s) {
            return .of(replacement(new: m[2]!, old: m[1]!, recipe: recipe))
        }
        if let m = Rx.firstMatch("^(?:subbed|substituted|subbed in|substituted in|sub|substitute|sub in|substitute in)\\s+(.+?)\\s+for\\s+(.+)$", in: s) {
            return .of(replacement(new: m[1]!, old: m[2]!, recipe: recipe))
        }
        if let m = Rx.firstMatch("^(?:swapped|swap|switched|switch|exchange)(?: out)?\\s+(.+?)\\s+(?:for|with)\\s+(.+)$", in: s) {
            return .of(replacement(new: m[2]!, old: m[1]!, recipe: recipe))
        }
        // "change the oil to 2 tbsp", "switch the chicken to thighs", "reduce the oil to 1 tbsp".
        if let m = Rx.firstMatch("^(change|switch|reduce|cut|cut back|lower|increase|up|bump up|raise)\\s+(.+?)\\s+to\\s+(.+)$", in: s),
           let original = findIngredient(m[2]!, in: recipe) {
            // Only "change"/"switch" can name another ingredient ("cut the chicken to bite-size
            // pieces" is not a swap).
            let amountOnly = !["change", "switch"].contains(m[1]!)
            // "to 2 tbsp": an amount of the same ingredient.
            let target = Rx.test("^[\\d½¼¾⅓⅔⅛]", m[3]!) ? m[3]! + " " + original.name : m[3]!
            return .of(use(target, for: original, amountOnly: amountOnly))
        }

        // Servings aren't an edit ("make it serve 6"): the stepper on the recipe scales amounts.
        if let n = Self.servings(in: s) {
            return ClauseResult(consumed: true, servings: n)
        }

        // Taste, with a negation guard ("wasn't too salty") and "hot" pans not counting as spicy.
        var negatedTaste = false
        for rule in tasteRules(recipe: recipe) {
            guard let hit = Self.tasteHit(rule.pattern, in: s, isHeat: rule.isHeat) else { continue }
            if hit.negated { negatedTaste = true; continue }
            return ClauseResult(edits: rule.action(), consumed: true, leftover: Self.leftover(s, excluding: hit.range))
        }
        if negatedTaste {
            // A negated taste phrase is praise, not a change: no edit, and no note unless
            // something else was said in the same clause.
            return ClauseResult(edits: [], consumed: true, leftover: Self.leftover(s, excluding: nil))
        }

        // Removals. "left the X out" / "skipped X" / "no X" (only when X is in the recipe).
        if let m = Rx.firstMatch("^(?:left|leave|take)\\s+(.+?)\\s+out$", in: s)
            ?? Rx.firstMatch("^(?:skipped|skip|left out|leave out|omitted|omit|didn't use|did not use|didn't add|did not add|didn't have|did not have|went without|forgot|remove|take out|drop|ditch|lose|cut out|get rid of|don't use|do not use|don't add|do not add|don't put in|do not put in|hold|go without|make it without|without)\\s+(.+)$", in: s) {
            return .of(removals(m[1]!, recipe: recipe))
        }
        if let m = Rx.firstMatch("^no\\s+(.+)$", in: s) {
            return .of(removals(m[1]!, recipe: recipe))
        }

        // Scaling.
        let scales: [(String, Double)] = [
            ("^(?:used\\s+|use\\s+)?(?:double|doubled)(?:\\s+up\\s+on)?\\s+(.+)$", 2),
            ("^(?:used\\s+|use\\s+)?(?:half|halved|halve)\\s+(?:of\\s+)?(.+)$", 0.5),
            ("^(?:cut|reduce|cut down|cut back)\\s+(.+?)\\s+(?:in|by)\\s+half$", 0.5),
            ("^(?:there was\\s+|it had\\s+)?too much\\s+(.+)$", 0.75),
            ("^(?:used\\s+|use\\s+|add\\s+|added\\s+|needs\\s+|needed\\s+|put\\s+)?(?:a (?:bit|little|touch|lot)\\s+)?less\\s+(.+)$", 0.75),
            ("^(?:cut back on|cut down on|cut down|reduced|reduce|go easy on|go light on|ease up on|tone down)\\s+(.+)$", 0.75),
            ("^(?:there was\\s+|it had\\s+)?not enough\\s+(.+)$", 1.25),
            ("^(?:used\\s+|use\\s+|add\\s+|added\\s+|needs\\s+|needed\\s+|wanted\\s+|could use\\s+|put\\s+)?(?:a (?:bit|little|touch|lot)\\s+)?(?:more|extra)\\s+(.+)$", 1.25),
            ("^(?:increase|bump up|boost)\\s+(.+)$", 1.25),
        ]
        for (pattern, factor) in scales {
            if let m = Rx.firstMatch(pattern, in: s) {
                let edits = scalings(m[1]!, factor: factor, recipe: recipe)
                if !edits.isEmpty { return .of(edits) }
            }
        }

        // Additions: "added X", "threw in X". Items already in the recipe become "more X".
        if let m = Rx.firstMatch("^(?:added|add|threw in|tossed in|stirred in|put in|topped (?:it )?with|finished (?:it )?with|garnished with|throw in|toss in|stir in|top (?:it )?with|finish (?:it )?with|garnish (?:it )?with)\\s+(.+)$", in: s) {
            let edits = additions(m[1]!, recipe: recipe)
            // An instruction ("add a squeeze of lime at the end") adds the new ingredient with its
            // timing as the line's note; a report ("added lime at the end") stays a note, as before.
            if edits.isEmpty, !Rx.test("^(?:added|threw|tossed|stirred|put|topped|finished|garnished)\\b", s) {
                return .of(timedAddition(m[1]!, recipe: recipe))
            }
            return .of(edits)
        }

        // "use 2 tbsp oil" (an amount), "use chicken thighs" (another form of a listed ingredient).
        if let m = Rx.firstMatch("^(?:use|only use|go with)\\s+(?:only\\s+|just\\s+)?(.+)$", in: s),
           let original = findIngredient(m[1]!, in: recipe) {
            return .of(use(m[1]!, for: original))
        }
        return .unmatched
    }

    // MARK: Taste

    struct TasteRule {
        var pattern: String
        var isHeat: Bool
        var action: () -> [RecipeEdit]
    }

    func tasteRules(recipe: Recipe) -> [TasteRule] {
        [
            TasteRule(pattern: "\\b(?:too|very|a bit|a little|slightly|way too|overly|quite)\\s+salty\\b|\\boversalted\\b", isHeat: false) {
                adjust(ids: ["salt", "soy-sauce", "dark-soy-sauce", "tamari", "fish-sauce"], factor: 0.75, recipe: recipe, fallbackNote: "Use less salt than last time")
            },
            TasteRule(pattern: "\\bnot (?:spicy|hot) enough\\b|\\b(?:too |a bit |a little |very |quite )?bland\\b|\\bneed(?:ed|s) more heat\\b", isHeat: false) {
                adjust(tags: .spicy, factor: 1.5, recipe: recipe, fallbackNote: "Season more boldly next time")
            },
            TasteRule(pattern: "\\b(?:too|very|a bit|a little|way too|overly|quite)\\s+(?:spicy|hot)\\b", isHeat: true) {
                adjust(tags: .spicy, factor: 0.5, recipe: recipe, fallbackNote: "Make it milder next time")
            },
            TasteRule(pattern: "\\b(?:too|very|a bit|a little|way too|overly|quite)\\s+sweet\\b", isHeat: false) {
                adjust(ids: ["sugar", "honey", "brown-sugar", "palm-sugar", "maple-syrup", "rock-sugar"], factor: 0.75, recipe: recipe, fallbackNote: "Use less sugar than last time")
            },
        ]
    }

    /// Cookware or heat-source words: "the pan was too hot" is about the stove, not chilli.
    static let heatSubjects = "\\b(?:pan|pans|oil|oven|grill|heat|stove|stovetop|hob|wok|skillet|burner|griddle|flame|plate|plates|water|tray|broiler)\\b"

    /// First match of `pattern` in `s`, and whether it is negated (not / never / no / …n't
    /// within three words before it). Nil when there is no match, or when a "hot" match has a
    /// cookware subject.
    static func tasteHit(_ pattern: String, in s: String, isHeat: Bool) -> (range: NSRange, negated: Bool)? {
        let ns = s as NSString
        guard let m = Rx.re(pattern).firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        if isHeat, ns.substring(with: m.range).hasSuffix("hot"), Rx.test(heatSubjects, s) { return nil }
        let before = ns.substring(to: m.range.location).split(separator: " ").suffix(3).map(String.init)
        let negated = before.contains { ["not", "never", "no", "hardly", "nor"].contains($0) || $0.hasSuffix("n't") }
        return (m.range, negated)
    }

    /// Other things said in the same clause ("…and the garlic burned"), split on and/but/while,
    /// excluding the part containing `range`. Nil when nothing of substance remains.
    static func leftover(_ s: String, excluding range: NSRange?) -> String? {
        let ns = s as NSString
        var parts: [String] = []
        var cursor = 0
        let separators = Rx.re("\\s+(?:and|but|while)\\s+").matches(in: s, range: NSRange(location: 0, length: ns.length))
        for sep in separators {
            let part = NSRange(location: cursor, length: sep.range.location - cursor)
            if range.map({ NSIntersectionRange($0, part).length == 0 }) ?? true { parts.append(ns.substring(with: part)) }
            cursor = sep.range.location + sep.range.length
        }
        let last = NSRange(location: cursor, length: ns.length - cursor)
        if range.map({ NSIntersectionRange($0, last).length == 0 }) ?? true { parts.append(ns.substring(with: last)) }
        // Without a separator there's no "other" part to keep.
        guard !separators.isEmpty else { return nil }
        let kept = parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ,")) }
            .filter { $0.split(separator: " ").count >= 2 && !Rx.test(filler, $0) && !Rx.test("\\b(?:salty|spicy|sweet|bland|hot)\\b", $0) }
        guard !kept.isEmpty else { return nil }
        let text = kept.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: Builders

    /// "use 2 tbsp oil" → the oil's amount; "use chicken thighs" → swap the chicken for thighs
    /// (keeping its amount). Nothing when the text says what the recipe already says.
    func use(_ text: String, for original: Ingredient, amountOnly: Bool = false) -> [RecipeEdit] {
        let parsed = IngredientLineParser.parse(Self.stripArticles(text))
        if parsed.name.isEmpty || isJustName(parsed.name, of: original) || amountOnly {
            guard parsed.name.isEmpty || isJustName(parsed.name, of: original) else { return [] }
            guard let quantity = parsed.quantity,
                  quantity != original.quantity || parsed.unit != original.unit else { return [] }
            var changed = original
            changed.quantity = quantity
            changed.unit = parsed.unit
            changed.raw = changed.displayText
            return [.replaceIngredient(id: original.id, with: [changed], reason: RecipeEdit.amountChangeReason)]
        }
        return replace(original, with: text).map { [$0] } ?? []
    }

    /// A new ingredient added at a particular moment: "a squeeze of lime at the end" → lime, with
    /// "a squeeze, at the end" as its note. Nothing for an ingredient already in the recipe.
    func timedAddition(_ text: String, recipe: Recipe) -> [RecipeEdit] {
        var rest = text.trimmed
        var notes: [String] = []
        if let m = Rx.firstMatch("^(a (?:little bit|bit|little|splash|squeeze|handful|pinch|dash|drizzle|sprinkle|few)(?: of)?)\\s+(.+)$", in: rest) {
            notes.append(Rx.replace("\\s+of$", in: m[1]!, with: ""))
            rest = m[2]!
        }
        if let m = Rx.firstMatch("^(.+?)\\s+((?:right |just )?(?:at the (?:end|start|beginning)|to finish|before serving|halfway(?: through)?|first|last))$", in: rest) {
            rest = m[1]!
            notes.append(m[2]!)
        }
        guard !notes.isEmpty, findIngredient(rest, in: recipe) == nil, var ing = newIngredient(rest),
              !Rx.test(Self.nonIngredientObject, ing.name.lowercased()),
              !Rx.test(Self.additionQualifiers, ing.name.lowercased()) else { return [] }
        ing.note = ([ing.note].compactMap { $0 } + notes).joined(separator: ", ")
        ing.raw = ing.displayText
        return [.addIngredient(ing)]
    }

    static let numberWords = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                              "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]

    /// "make it serve 6", "scale it to 8 people", "make it for four", "change servings to 2".
    static func servings(in s: String) -> Int? {
        let n = "(\\d+|" + numberWords.keys.joined(separator: "|") + ")"
        let people = "(?:\\s+(?:people|persons|servings|portions|of us|adults))?"
        let patterns = [
            "^(?:make (?:it|this|the recipe) |scale (?:it|this|the recipe) (?:up |down )?to )?(?:serve|serves|feed|feeds)\\s+\(n)\(people)$",
            "^(?:make (?:it|this|the recipe|enough|it enough)|scale (?:it|this|the recipe)?\\s*(?:up|down)?|cook)\\s+(?:for|to)\\s+\(n)\(people)$",
            "^(?:change|set|make)\\s+(?:the\\s+)?(?:servings?|portions?|yield)\\s+(?:to\\s+)?\(n)$",
            "^\(n)\\s+(?:servings|portions)$",
        ]
        for pattern in patterns {
            guard let m = Rx.firstMatch(pattern, in: s), let word = m[1] else { continue }
            if let value = Int(word) ?? numberWords[word], (1...50).contains(value) { return value }
        }
        return nil
    }

    func replacement(new: String, old: String, recipe: Recipe) -> [RecipeEdit] {
        guard let original = findIngredient(old, in: recipe), let edit = replace(original, with: new) else { return [] }
        return [edit]
    }

    /// Objects that aren't ingredients: "didn't have time to…", "forgot to rest…", "no rice cooker".
    static let nonIngredientObject = "^(?:time|enough time|the time|a chance|any time|to)\\b|\\b(?:cooker|pan|pot|oven|time|chance|blender|processor|grill|wok|thermometer|timer|steamer)s?\\b"

    func removals(_ text: String, recipe: Recipe) -> [RecipeEdit] {
        guard !Rx.test(Self.nonIngredientObject, Self.stripArticles(text)) else { return [] }
        let parts = Self.listItems(text)
        let found = parts.compactMap { findIngredient($0, in: recipe) }
        // All-or-nothing: "no problems with the chicken" shouldn't remove the chicken.
        guard !found.isEmpty, found.count == parts.count else { return [] }
        return found.map { .removeIngredient(id: $0.id) }
    }

    func scalings(_ text: String, factor: Double, recipe: Recipe) -> [RecipeEdit] {
        let parts = Self.listItems(text)
        let found = parts.compactMap { findIngredient($0, in: recipe) }
        guard !found.isEmpty, found.count == parts.count else { return [] }
        return found.map { scale($0, factor: factor) }
    }

    /// Timing or manner phrases that make "added X …" a remark rather than an ingredient change.
    static let additionQualifiers = "\\b(?:at the (?:end|start|beginning)|too (?:early|late|soon)|earlier|later|first|last|before|after|halfway|at once|all at once)\\b"

    func additions(_ text: String, recipe: Recipe) -> [RecipeEdit] {
        var edits: [RecipeEdit] = []
        for part in Self.listItems(text) {
            if let m = Rx.firstMatch("^(?:more|extra|a bit more|a little more|some more)\\s+(.+)$", in: part) {
                guard let ing = findIngredient(m[1]!, in: recipe), isJustName(m[1]!, of: ing) else { return [] }
                edits.append(scale(ing, factor: 1.25))
                continue
            }
            let parsed = catalog.annotate(IngredientLineParser.parse(Self.stripArticles(part)))
            guard !parsed.name.isEmpty else { continue }
            if let existing = findIngredient(part, in: recipe) {
                // "added the garlic" → more garlic; "added the garlic at the end" → keep as a note.
                guard isJustName(parsed.name, of: existing) else { return [] }
                edits.append(parsed.quantity == nil ? scale(existing, factor: 1.25) : .addIngredient(parsed))
            } else {
                guard !Rx.test(Self.additionQualifiers, part) else { return [] }
                edits.append(.addIngredient(parsed))
            }
        }
        return edits
    }

    /// True when `text` names `ingredient` and says nothing else (ignoring articles).
    func isJustName(_ text: String, of ingredient: Ingredient) -> Bool {
        let words = Self.contentWords(text, dropGeneric: false)
        guard !words.isEmpty else { return false }
        var known = Set(IngredientCatalog.normalise(ingredient.name).split(separator: " ").map(String.init))
        if let id = ingredient.catalogID ?? catalog.match(ingredient.name)?.id, let entry = catalog.entry(id: id) {
            for name in entry.names { known.formUnion(IngredientCatalog.normalise(name).split(separator: " ").map(String.init)) }
        }
        return words.isSubset(of: known)
    }

    /// Replaces `original` with an ingredient parsed from `text` ("chicken thighs", "1 tbsp lime juice"),
    /// keeping the original amount unless `text` gives one. Nil if `text` has no name.
    public func replace(_ original: Ingredient, with text: String) -> RecipeEdit? {
        let parsed = IngredientLineParser.parse(Self.stripArticles(text))
        guard !parsed.name.isEmpty, parsed.name.lowercased() != original.name.lowercased() else { return nil }
        let hasOwnAmount = parsed.quantity != nil
        var replacement = catalog.annotate(Ingredient(
            raw: "",
            quantity: hasOwnAmount ? parsed.quantity : original.quantity,
            unit: hasOwnAmount ? parsed.unit : original.unit,
            name: parsed.name, note: parsed.note))
        replacement.raw = replacement.displayText
        return .replaceIngredient(id: original.id, with: [replacement], reason: "Used \(parsed.name) instead of \(original.name)")
    }

    /// A new ingredient parsed from free text, matched to the catalog.
    public func newIngredient(_ text: String) -> Ingredient? {
        let parsed = catalog.annotate(IngredientLineParser.parse(Self.stripArticles(text)))
        return parsed.name.isEmpty ? nil : parsed
    }

    /// Amendment: scaling an ingredient without a quantity becomes a note instead of a no-op.
    /// Things counted whole ("3 cloves garlic", "2 eggs") are scaled to a whole number.
    public func scale(_ ingredient: Ingredient, factor: Double) -> RecipeEdit {
        guard let quantity = ingredient.quantity, quantity > 0 else {
            let word = factor < 1 ? "less" : "more"
            return .addNote(noteText("Use \(word) \(ingredient.name.lowercased()) than last time"))
        }
        return .scaleIngredient(id: ingredient.id, factor: Self.wholeFactor(factor, for: ingredient, quantity: quantity))
    }

    /// Units counted in whole pieces. An ingredient with no unit and a whole amount ("2 eggs",
    /// "3 green chillies", "1 onion") is counted too.
    static let wholeUnits: Set<String> = ["clove", "can", "slice", "stalk", "sprig", "piece", "packet", "head", "stick", "pod",
                                         "leaf", "bunch", "whole", "egg", "tin", "fillet", "breast", "thigh", "sheet"]

    /// `factor` adjusted so a counted ingredient lands on a whole number: 3 cloves × 1.25 → 4,
    /// 3 × 0.75 → 2; it always moves by at least one, and never below one (½ for a single item).
    static func wholeFactor(_ factor: Double, for ingredient: Ingredient, quantity q: Double) -> Double {
        let isWhole = abs(q - q.rounded()) < 0.001
        let counted = ingredient.unit.map { wholeUnits.contains($0.lowercased()) } ?? isWhole
        guard counted, isWhole, abs(factor - 1) > 0.001 else { return factor }
        var target = (q * factor).rounded()
        if target == q { target = factor > 1 ? q + 1 : q - 1 }
        if target < 1 { target = factor < 1 && q <= 1 ? 0.5 : 1 }
        return target / q
    }

    /// A rule's note: "Use less salt than last time" in a report, "Use less salt" as an instruction.
    func noteText(_ text: String) -> String {
        guard kind == .change else { return text }
        return Rx.replace("\\s+(?:than last time|next time)$", in: text, with: "")
    }

    func adjust(ids: Set<String>, factor: Double, recipe: Recipe, fallbackNote: String) -> [RecipeEdit] {
        let targets = recipe.ingredients.filter { ($0.catalogID ?? catalog.match($0.name)?.id).map(ids.contains) ?? false }
        return targets.isEmpty ? [.addNote(noteText(fallbackNote))] : targets.map { scale($0, factor: factor) }
    }

    func adjust(tags tag: IngredientTag, factor: Double, recipe: Recipe, fallbackNote: String) -> [RecipeEdit] {
        let targets = recipe.ingredients.filter { ing in
            let entry = ing.catalogID.flatMap(catalog.entry(id:)) ?? catalog.match(ing.name)
            return entry?.tags.contains(tag) == true
        }
        return targets.isEmpty ? [.addNote(noteText(fallbackNote))] : targets.map { scale($0, factor: factor) }
    }

    /// The cook's own wording for an ingredient ("4 cloves garlic", "chicken thighs") as an edit:
    /// an amount change for the same ingredient, a swap otherwise. Nil when nothing changes.
    public func ingredientChange(_ original: Ingredient, to text: String) -> RecipeEdit? {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty, trimmed.lowercased() != original.displayText.lowercased() else { return nil }
        return use(trimmed, for: original).first
    }

    // MARK: Matching

    static let stopWords: Set<String> = ["the", "a", "an", "some", "of", "my", "our", "it", "them", "bit", "little", "more", "less", "fresh", "whole", "and", "with", "to", "in", "on", "for"]

    /// Head words shared by many ingredients; matching on them alone picks the wrong one
    /// ("more fish sauce" must not mean the soy sauce). Compared after `normalise` (singular).
    static let genericWords: Set<String> = [
        "sauce", "oil", "powder", "paste", "seed", "leave", "leaf", "juice", "stock", "broth", "flour",
        "vinegar", "wine", "milk", "water", "meat", "fillet", "piece", "mince", "ground", "dried", "spice",
        "mix", "cream", "sugar", "salt", "pepper", "cheese", "noodle", "bean",
    ]

    /// Words that make an ingredient a different product from the thing it's named after.
    static let productWords: Set<String> = ["oil", "butter", "milk", "flour", "vinegar", "wine", "extract", "stock", "broth"]

    /// True when `ingredient` is made from what `said` names: a said word directly followed by a
    /// product word that wasn't said ("peanut oil" for "peanuts"; not "sherry or rice wine").
    static func isProduct(_ ingredient: Ingredient, of said: Set<String>) -> Bool {
        let tokens = IngredientCatalog.normalise(ingredient.name).split(separator: " ").map(String.init)
        return tokens.indices.dropLast().contains { i in
            said.contains(tokens[i]) && productWords.contains(tokens[i + 1]) && !said.contains(tokens[i + 1])
        }
    }

    static func contentWords(_ text: String, dropGeneric: Bool) -> Set<String> {
        var words = Set(IngredientCatalog.normalise(stripArticles(text)).split(separator: " ").map(String.init))
            .subtracting(stopWords)
        if dropGeneric { words.subtract(genericWords) }
        return words
    }

    static func stripArticles(_ text: String) -> String {
        Rx.replace("^(?:a little bit of|a bit of|a little|a splash of|a squeeze of|a handful of|a pinch of|a dash of|the|a|an|some|my|our)\\s+", in: text.trimmed, with: "")
    }

    static func listItems(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",&"))
            .flatMap { $0.components(separatedBy: " and ") }
            .map { stripArticles($0.collapsedWhitespace) }
            .filter { !$0.isEmpty }
    }

    /// Recipe ingredient referred to by `text`: same catalog ID first. If the catalog knows the
    /// text but that entry isn't in the recipe, only an ingredient whose name contains every
    /// word of it counts ("chicken" → "chicken thighs", but never "fish sauce" → "soy sauce").
    /// Otherwise, best overlap on non-generic words.
    public func findIngredient(_ text: String, in recipe: Recipe) -> Ingredient? {
        let cleaned = Self.stripArticles(text)
        guard !cleaned.isEmpty else { return nil }
        func words(_ ing: Ingredient) -> Set<String> {
            Set(IngredientCatalog.normalise(ing.name).split(separator: " ").map(String.init))
        }
        if let id = catalog.match(cleaned)?.id {
            if let hit = recipe.ingredients.first(where: { ($0.catalogID ?? catalog.match($0.name)?.id) == id }) {
                return hit
            }
            let all = Self.contentWords(cleaned, dropGeneric: false)
            guard !all.isEmpty, !all.isSubset(of: Self.genericWords) else { return nil }
            // "peanuts" is not the peanut oil, nor "sesame" the sesame oil: a product made from it.
            return recipe.ingredients.first { all.isSubset(of: words($0)) && !Self.isProduct($0, of: all) }
        }
        let content = Self.contentWords(cleaned, dropGeneric: true)
        guard !content.isEmpty else { return nil }
        var best: (Ingredient, Int)?
        let said = Self.contentWords(cleaned, dropGeneric: false)
        for ing in recipe.ingredients where !Self.isProduct(ing, of: said) {
            let overlap = content.intersection(words(ing)).count
            if overlap > 0, overlap > (best?.1 ?? 0) { best = (ing, overlap) }
        }
        return best?.0
    }
}
