import Foundation

public enum PrepGroupKind: String, CaseIterable, Codable, Hashable, Sendable {
    case startEarly, chopAndPrep, mixAhead, getOut

    public var title: String {
        switch self {
        case .startEarly: "Start early"
        case .chopAndPrep: "Chop and prep"
        case .mixAhead: "Mix ahead"
        case .getOut: "Get out"
        }
    }
}

/// One line of the prep list. Ingredients are referenced by ID, so the text is rendered from
/// whatever (scaled) recipe is shown.
public struct PrepItem: Hashable, Sendable, Identifiable {
    public var id: String
    /// "Thinly slice", "Mix the sauce:", "Marinate", "Preheat the oven to 200°C". Empty for "Get out".
    public var action: String
    /// Ingredients this item covers. Each recipe ingredient is covered exactly once per plan.
    public var ingredientIDs: [UUID]
    /// Per-ingredient detail shown after it ("in rings", "or tamari").
    public var details: [UUID: String]
    /// Shown when the item covers no ingredients: "the chicken" in "Marinate the chicken".
    public var subject: String?
    /// Text after the list: "in a small bowl".
    public var suffix: String?
    /// "Marinate A with B and C" rather than "Marinate A, B and C".
    public var withRest: Bool
    /// For "Start early": how long it takes, when the step says.
    public var minutes: Int?
    /// The step it comes from (index into `Recipe.steps`).
    public var step: Int?

    public init(id: String, action: String, ingredientIDs: [UUID] = [], details: [UUID: String] = [:], subject: String? = nil,
                suffix: String? = nil, withRest: Bool = false, minutes: Int? = nil, step: Int? = nil) {
        self.id = id
        self.action = action
        self.ingredientIDs = ingredientIDs
        self.details = details
        self.subject = subject
        self.suffix = suffix
        self.withRest = withRest
        self.minutes = minutes
        self.step = step
    }

    /// "Slice ½ onion, 1 green bell pepper and 2 Fresnos (in rings)", with amounts from `recipe`.
    public func text(in recipe: Recipe) -> String {
        let phrases = ingredientIDs.compactMap { id -> String? in
            guard let ing = recipe.ingredient(id: id) else { return nil }
            guard let detail = details[id], !detail.isEmpty else { return ing.displayText }
            return detail.hasPrefix("into ") ? "\(ing.displayText) \(detail)" : "\(ing.displayText) (\(detail))"
        }
        var text: String
        if phrases.isEmpty {
            text = [action, subject].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        } else {
            let list = withRest && phrases.count > 1
                ? "\(phrases[0]) with \(RecipeEdit.list(Array(phrases.dropFirst())))"
                : RecipeEdit.list(phrases)
            text = action.isEmpty ? list : "\(action) \(list)"
        }
        if let suffix, !suffix.isEmpty { text += suffix.hasPrefix(",") ? suffix : " \(suffix)" }
        return RecipeFormatText.capitalisedFirst(text)
    }
}

public struct PrepGroup: Hashable, Sendable, Identifiable {
    public var kind: PrepGroupKind
    public var items: [PrepItem]
    public var id: PrepGroupKind { kind }

    public init(kind: PrepGroupKind, items: [PrepItem]) {
        self.kind = kind
        self.items = items
    }
}

/// The "Mise en place" list shown before the first step.
public struct PrepPlan: Hashable, Sendable {
    public enum Source: String, Hashable, Sendable { case rules, model }

    /// Non-empty groups in a fixed order: start early, chop and prep, mix ahead, get out.
    public var groups: [PrepGroup]
    public var source: Source

    public init(groups: [PrepGroup], source: Source) {
        self.groups = PrepGroupKind.allCases.compactMap { kind in
            let items = groups.filter { $0.kind == kind }.flatMap(\.items)
            return items.isEmpty ? nil : PrepGroup(kind: kind, items: items)
        }
        self.source = source
    }

    public var items: [PrepItem] { groups.flatMap(\.items) }

    /// Every covered ingredient ID, in plan order (each should appear once).
    public var coveredIDs: [UUID] { items.flatMap(\.ingredientIDs) }

    public func group(_ kind: PrepGroupKind) -> PrepGroup? { groups.first { $0.kind == kind } }

    /// Plain text, one group heading per block, for logs and tests.
    public func text(in recipe: Recipe) -> String {
        groups.map { group in
            ([group.kind.title] + group.items.map { item in
                var line = "- " + item.text(in: recipe)
                if let minutes = item.minutes { line += " · \(minutes) min" }
                if let step = item.step, group.kind == .startEarly { line += " (step \(step + 1))" }
                return line
            }).joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

/// Builds the prep list with rules. See `plan(for:)`.
public struct PrepPlanner: Sendable {
    public let catalog: IngredientCatalog

    public init(catalog: IngredientCatalog = .shared) {
        self.catalog = catalog
    }

    /// A key that changes whenever the recipe's ingredients or steps change; used to cache plans
    /// per recipe revision.
    public static func fingerprint(_ recipe: Recipe) -> String {
        let ingredients = recipe.ingredients.map { "\($0.id.uuidString)|\($0.name)|\($0.note ?? "")" }.joined(separator: "\n")
        return "\(recipe.title)\n\(ingredients)\n--\n\(recipe.steps.joined(separator: "\n"))"
    }

    /// Groups, in order of who claims an ingredient first:
    /// 1. **Chop and prep**: a cutting word in the ingredient's note ("thinly sliced", "minced"),
    ///    or a step clause that starts with a prep verb ("Slice ½ onion, …", "Toast and grind …"),
    ///    or a participle right before the mention ("add the chopped onion"). One item per verb.
    /// 2. **Start early**: "softened"/"room temperature" notes; marinating, soaking, rising or
    ///    chilling (≥ 5 min, untimed or overnight) and resting/standing (≥ 10 min) in a step before
    ///    the first heat step (`TimeEstimator.passiveLabel`); preheating the oven; boiling water.
    ///    A marinade step that mixes things covers its not-yet-claimed ingredients.
    /// 3. **Mix ahead**: a step before the first heat step that mixes, whisks or combines, or puts
    ///    things in a bowl, and names at least two ingredients: its unclaimed ingredients.
    /// 4. **Get out**: everything else, in recipe order.
    public func plan(for recipe: Recipe) -> PrepPlan {
        let links = StepIngredientLinker(catalog: catalog).links(for: recipe)
        let texts = recipe.steps.map(StepIngredientLinker.folded)
        let masked = texts.indices.map { Self.mask(texts[$0], links.mentions[$0]) }
        let firstHeat = masked.firstIndex(where: Self.isHeat) ?? recipe.steps.count
        var covered: Set<UUID> = []
        var details: [UUID: String] = [:]
        for ing in recipe.ingredients {
            if let note = ing.note, let cleaned = Self.cleanNote(note) { details[ing.id] = cleaned }
        }

        // 1. Chop and prep.
        var verbFor: [UUID: String] = [:]
        var verbOrder: [String] = []
        var startEarlyNotes: [(id: UUID, action: String, suffix: String?)] = []
        func assign(_ id: UUID, _ verb: String) {
            guard verbFor[id] == nil, !startEarlyNotes.contains(where: { $0.id == id }) else { return }
            verbFor[id] = verb
            if !verbOrder.contains(verb) { verbOrder.append(verb) }
        }
        for ing in recipe.ingredients {
            guard let note = ing.note else { continue }
            if let early = Self.startEarlyNote(note) {
                startEarlyNotes.append((ing.id, early.action, early.suffix))
                details[ing.id] = Self.cleanNote(note, removing: early.matched)
                continue
            }
            if let found = Self.prepVerb(inNote: note) {
                assign(ing.id, found.verb)
                details[ing.id] = Self.cleanNote(note, removing: found.matched)
            }
        }
        for (s, text) in texts.enumerated() {
            for clause in Self.clauseRanges(text) {
                let clauseText = (text as NSString).substring(with: clause)
                let inClause = links.mentions[s].filter { NSIntersectionRange($0.range, clause).length > 0 }
                if let verb = Self.leadingPrepVerb(clauseText) {
                    for m in inClause { assign(m.ingredientID, verb) }
                    continue
                }
                for m in inClause {
                    let before = (text as NSString).substring(with: NSRange(location: clause.location, length: m.range.location - clause.location))
                    if let verb = Self.participleBefore(before) { assign(m.ingredientID, verb) }
                }
            }
        }
        var chopItems: [PrepItem] = []
        for verb in verbOrder {
            let ids = recipe.ingredients.map(\.id).filter { verbFor[$0] == verb && !covered.contains($0) }
            guard !ids.isEmpty else { continue }
            covered.formUnion(ids)
            chopItems.append(PrepItem(id: "chop.\(chopItems.count)", action: verb, ingredientIDs: ids, details: details.filter { ids.contains($0.key) }))
        }

        // 2. Start early.
        var early: [PrepItem] = []
        let noteActions = startEarlyNotes.filter { !covered.contains($0.id) }
        for action in Self.ordered(noteActions.map(\.action)) {
            let ids = noteActions.filter { $0.action == action }.map(\.id)
            covered.formUnion(ids)
            early.append(PrepItem(id: "early.\(early.count)", action: action, ingredientIDs: ids, details: details.filter { ids.contains($0.key) },
                                  suffix: noteActions.first { $0.action == action }?.suffix))
        }
        for (s, text) in texts.enumerated() {
            let ns = text as NSString
            let original = recipe.steps[s]
            if let preheat = Rx.firstMatch("\\bpre-?heat (?:the |your )?(?:oven|grill|broiler|air fryer)[^.;,(]*", in: original)?[0] {
                early.append(PrepItem(id: "early.\(early.count)", action: Self.shorten(preheat), step: s))
            }
            if let warm = Rx.firstMatch("\\b(?:bring|let|allow)\\b[^.;]{0,60}?\\b(?:to |come to )room temperature", in: original)?[0] {
                early.append(PrepItem(id: "early.\(early.count)", action: Self.shorten(warm), step: s))
            }
            if Rx.test("\\bbring (?:a |the )?(?:large |big |medium |small )?(?:pot|pan|saucepan) of (?:salted )?water to (?:a |the )?(?:rolling )?boil|\\bboil(?:ing|ed)? (?:some )?water\\b|\\bboil (?:the |some )?water\\b|\\bkettle\\b", text) {
                let subject = links.mentions[s].first { recipe.ingredient(id: $0.ingredientID)?.catalogID != "water" }
                    .map { "for the " + ns.substring(with: $0.range) }
                early.append(PrepItem(id: "early.\(early.count)", action: "Boil water", subject: subject, step: s))
            }
            guard s < firstHeat || firstHeat == recipe.steps.count else { continue }
            for clause in Self.clauseRanges(text) {
                let clauseText = ns.substring(with: clause)
                guard let label = TimeEstimator.passiveLabel(clauseText) else { continue }
                let durations = TimeEstimator.durations(in: clauseText)
                let minutes = durations.map(\.minutes).max()
                let overnight = durations.contains { $0.overnight }
                let qualifies: Bool
                switch label {
                case "marinating", "soaking", "rising", "chilling", "overnight":
                    qualifies = (minutes ?? 5) >= 5 && (firstHeat < recipe.steps.count || label != "chilling")
                case "resting", "standing":
                    qualifies = (minutes ?? 0) >= 10 && firstHeat < recipe.steps.count
                default:
                    qualifies = false
                }
                guard qualifies else { continue }
                // A marinade mixed in this step covers its unclaimed ingredients.
                let upToClause = links.mentions[s].filter { $0.range.location < clause.location + clause.length }
                var ids: [UUID] = []
                if Rx.test("\\b(?:mix|mixed|combine|toss|coat|rub|whisk|stir)\\b", ns.substring(to: clause.location + clause.length)) {
                    for m in upToClause where !covered.contains(m.ingredientID) && !ids.contains(m.ingredientID) { ids.append(m.ingredientID) }
                }
                covered.formUnion(ids)
                let subject = upToClause.first.map { "the " + ns.substring(with: $0.range) }
                early.append(PrepItem(id: "early.\(early.count)", action: Self.passiveVerb(label), ingredientIDs: ids,
                                      details: details.filter { ids.contains($0.key) }, subject: subject, withRest: true,
                                      minutes: overnight ? nil : minutes.map { Int($0.rounded(.up)) }, step: s))
                break  // one per step
            }
        }

        // 3. Mix ahead.
        var mix: [PrepItem] = []
        for s in texts.indices where s < firstHeat {
            let stepLinks = links.steps[s]
            guard stepLinks.count >= 2 else { continue }
            let ids = stepLinks.filter { !covered.contains($0) }
            guard !ids.isEmpty, let shape = Self.mixShape(masked[s]) else { continue }
            covered.formUnion(ids)
            mix.append(PrepItem(id: "mix.\(mix.count)", action: shape.action, ingredientIDs: ids,
                                details: details.filter { ids.contains($0.key) }, suffix: shape.suffix, step: s))
        }

        // 4. Get out.
        let rest = recipe.ingredients.filter { !covered.contains($0.id) }
        let getOut = rest.enumerated().map { n, ing in
            PrepItem(id: "out.\(n)", action: "", ingredientIDs: [ing.id], details: details.filter { $0.key == ing.id })
        }

        return PrepPlan(groups: [
            PrepGroup(kind: .startEarly, items: early),
            PrepGroup(kind: .chopAndPrep, items: chopItems),
            PrepGroup(kind: .mixAhead, items: mix),
            PrepGroup(kind: .getOut, items: getOut),
        ], source: .rules)
    }

    // MARK: Model output

    /// Maps a model's plan. Rules:
    /// - The rules' "Start early" items are kept as they are (they carry step times); their
    ///   ingredients are taken out of the model's items.
    /// - Names map to recipe ingredients by name or catalog entry, each ingredient once (first
    ///   item wins; a name listed twice in the recipe maps to the next unclaimed line).
    /// - Actions are cut to one short line without digits (amounts come from the recipe, so they
    ///   scale); otherwise the group's default verb is used.
    /// - Items that cover nothing are dropped. If more than a quarter of the names don't match a
    ///   recipe ingredient, or nothing maps at all, the plan is invalid (nil): use the rules.
    /// - Anything left uncovered is added to "Get out".
    public func map(_ proposal: [ProposedPrepGroup], recipe: Recipe, rules: PrepPlan) -> PrepPlan? {
        let early = rules.group(.startEarly)?.items ?? []
        var covered = Set(early.flatMap(\.ingredientIDs))
        var details: [UUID: String] = [:]
        for ing in recipe.ingredients {
            if let note = ing.note, let cleaned = Self.cleanNote(note) { details[ing.id] = cleaned }
        }
        var groups: [PrepGroupKind: [PrepItem]] = [.startEarly: early]
        var total = 0, unmatched = 0, mapped = 0
        for group in proposal.prefix(4) {
            for item in group.items.prefix(12) {
                var ids: [UUID] = []
                for name in item.ingredients.prefix(12) where !name.trimmed.isEmpty {
                    total += 1
                    guard let id = matchIngredient(name, in: recipe, excluding: covered.union(ids), alreadyCovered: covered) else {
                        unmatched += 1
                        continue
                    }
                    if let id = id { ids.append(id) }
                }
                guard !ids.isEmpty else { continue }
                mapped += ids.count
                covered.formUnion(ids)
                let action = Self.cleanAction(item.action) ?? Self.defaultAction(group.kind)
                // Drop "thinly sliced" from the detail when the action already says "slice".
                var itemDetails = details.filter { ids.contains($0.key) }
                for id in ids {
                    guard let note = recipe.ingredient(id: id)?.note, let found = Self.prepVerb(inNote: note),
                          let verb = found.verb.split(separator: " ").last,
                          action.lowercased().contains(verb.lowercased()) else { continue }
                    itemDetails[id] = Self.cleanNote(note, removing: found.matched)
                }
                let n = groups[group.kind, default: []].count
                groups[group.kind, default: []].append(PrepItem(
                    id: "\(group.kind.rawValue).m\(n)", action: group.kind == .getOut ? "" : action, ingredientIDs: ids,
                    details: itemDetails))
            }
        }
        guard mapped > 0, total > 0, Double(unmatched) <= Double(total) * 0.25 else { return nil }
        // Split "Get out" into one line per ingredient, and add whatever the model left out.
        var getOut = groups[.getOut, default: []].flatMap(\.ingredientIDs)
        getOut += recipe.ingredients.map(\.id).filter { !covered.contains($0) }
        groups[.getOut] = getOut.enumerated().map { n, id in
            PrepItem(id: "out.\(n)", action: "", ingredientIDs: [id], details: details.filter { $0.key == id })
        }
        return PrepPlan(groups: PrepGroupKind.allCases.map { PrepGroup(kind: $0, items: groups[$0] ?? []) }, source: .model)
    }

    /// `.some(id)` for a recipe ingredient; `.some(nil)` for a real ingredient that's already
    /// covered (a repeat, not an invention); nil when the name matches nothing in the recipe.
    func matchIngredient(_ name: String, in recipe: Recipe, excluding: Set<UUID>, alreadyCovered: Set<UUID>) -> UUID?? {
        let norm = IngredientCatalog.normalisedName(IngredientLineParser.parse(name).name)
        let entryID = catalog.match(name)?.id
        let candidates = recipe.ingredients.filter { ing in
            let ingNorm = IngredientCatalog.normalisedName(ing.name)
            if ingNorm == norm || IngredientCatalog.normalise(ing.name) == IngredientCatalog.normalise(name) { return true }
            if let entryID, (ing.catalogID ?? catalog.match(ing.name)?.id) == entryID { return true }
            return StepIngredientLinker.nameParts(ing.name).contains(norm)
        }
        guard !candidates.isEmpty else { return nil }
        if let free = candidates.first(where: { !excluding.contains($0.id) }) { return .some(free.id) }
        return .some(nil)
    }

    static func cleanAction(_ action: String) -> String? {
        var a = action.split(whereSeparator: \.isNewline).first.map(String.init)?.collapsedWhitespace ?? ""
        while a.hasSuffix(":") || a.hasSuffix(".") || a.hasSuffix("-") { a = String(a.dropLast()).trimmed }
        guard !a.isEmpty, a.count <= 40, a.rangeOfCharacter(from: .decimalDigits) == nil,
              !Rx.test("[½¼¾⅓⅔⅛]", a) else { return nil }
        return RecipeFormatText.capitalisedFirst(a)
    }

    static func defaultAction(_ kind: PrepGroupKind) -> String {
        switch kind {
        case .startEarly: "Start"
        case .chopAndPrep: "Prep"
        case .mixAhead: "Mix"
        case .getOut: ""
        }
    }

    // MARK: Text rules

    static let adverb = "(?:very finely|finely|thinly|roughly|coarsely|lightly|freshly)"
    static let participles: [(pattern: String, verb: String)] = [
        ("sliced", "slice"), ("chopped", "chop"), ("diced", "dice"), ("minced", "mince"), ("grated", "grate"),
        ("shredded", "shred"), ("julienned", "julienne"), ("crushed", "crush"), ("cubed", "cube"), ("halved", "halve"),
        ("quartered", "quarter"), ("peeled", "peel"), ("zested", "zest"), ("juiced", "juice"), ("trimmed", "trim"),
        ("torn", "tear"), ("smashed", "smash"), ("deseeded", "deseed"), ("seeded", "deseed"), ("pitted", "pit"),
        ("rinsed", "rinse"), ("drained", "drain"), ("beaten", "beat"), ("melted", "melt"), ("cut", "cut"),
        ("thinly", "slice"),
    ]

    /// The first cutting word in a note: "6 oz, thinly sliced" → ("Thinly slice", "thinly sliced").
    static func prepVerb(inNote note: String) -> (verb: String, matched: String)? {
        // "or 3 cloves garlic, minced" describes an alternative, not this ingredient.
        guard !Rx.test("^\\W*or\\b", note) else { return nil }
        var best: (verb: String, matched: String, location: Int)?
        for (word, verb) in participles where word != "thinly" {
            guard let m = Rx.re("\\b(\(adverb)\\s+)?\(word)\\b").firstMatch(in: note, range: NSRange(location: 0, length: (note as NSString).length)) else { continue }
            if best == nil || m.range.location < best!.location {
                let matched = (note as NSString).substring(with: m.range)
                let adv = m.range(at: 1).location != NSNotFound ? (note as NSString).substring(with: m.range(at: 1)).trimmed.lowercased() : nil
                let phrase = [adv == "freshly" ? nil : adv, verb].compactMap { $0 }.joined(separator: " ")
                best = (RecipeFormatText.capitalisedFirst(phrase), matched, m.range.location)
            }
        }
        return best.map { ($0.verb, $0.matched) }
    }

    /// "softened", "at room temperature" → "Bring to room temperature"; "soaked" → "Soak".
    static func startEarlyNote(_ note: String) -> (action: String, suffix: String?, matched: String)? {
        if let m = Rx.firstMatch("\\b(?:softened|(?:at |to )?room temperature)\\b", in: note)?[0] {
            return ("Bring", "to room temperature", m)
        }
        if let m = Rx.firstMatch("\\bsoaked\\b", in: note)?[0] { return ("Soak", nil, m) }
        return nil
    }

    /// Imperative prep verbs at the start of a clause. Mixing verbs ("beat", "whisk") are not prep.
    static let prepVerbs = "toast and grind|slice|chop|dice|mince|grate|shred|julienne|crush|peel|cut|trim|zest|halve|quarter|tear|smash|deseed|grind|pound|rinse|drain|wash"

    /// "Slice ½ onion, …" → "Slice"; "Finely chop the herbs" → "Finely chop".
    static func leadingPrepVerb(_ clause: String) -> String? {
        guard let m = Rx.firstMatch("^\\W*((?:\(adverb)\\s+)?(?:\(prepVerbs)))\\b", in: clause), let verb = m[1] else { return nil }
        return RecipeFormatText.capitalisedFirst(verb.lowercased())
    }

    /// "add the chopped " → "Chop".
    static func participleBefore(_ text: String) -> String? {
        let words = participles.filter { $0.pattern != "thinly" && $0.pattern != "cut" && $0.pattern != "melted" && $0.pattern != "beaten" }
        let alternation = words.map(\.pattern).joined(separator: "|")
        guard let m = Rx.firstMatch("\\b(\(adverb)\\s+)?(\(alternation))\\s+(?:[\\p{L}-]+\\s+){0,2}$", in: text),
              let word = m[2]?.lowercased(), let verb = participles.first(where: { $0.pattern == word })?.verb else { return nil }
        let adv = m[1]?.trimmed.lowercased()
        return RecipeFormatText.capitalisedFirst([adv == "freshly" ? nil : adv, verb].compactMap { $0 }.joined(separator: " "))
    }

    /// The note without references ("Note 3"), alternative amounts ("6 oz,") and the matched
    /// prep words. Nil when nothing is left.
    static func cleanNote(_ note: String, removing matched: String? = nil) -> String? {
        var n = note
        if let matched { n = n.replacingOccurrences(of: matched, with: "", options: .caseInsensitive) }
        n = Rx.replace("\\(?\\bnote\\s*\\d+[^)]*\\)?", in: n, with: "")
        n = Rx.replace("^\\s*[\\d.,/½¼¾⅓⅔\\s]+\\s*(?:g|kg|oz|lb|ml|l|cups?|tbsp|tsp)\\b\\s*,?", in: n, with: "")
        n = Rx.replace("\\(\\s*\\)", in: n, with: "")
        n = n.collapsedWhitespace
        n = Rx.replace("^(?:[,;:]|and\\b)\\s*|\\s*(?:[,;:(]|\\band)\\s*$", in: n, with: "")
        n = Rx.replace("^or\\b", in: n, with: "or")  // "OR Mirin" → "or Mirin"
        n = Rx.replace("\\s+,", in: n, with: ",").trimmed
        return n.isEmpty ? nil : n
    }

    static func passiveVerb(_ label: String) -> String {
        switch label {
        case "marinating": "Marinate"
        case "soaking": "Soak"
        case "rising": "Let rise:"
        case "chilling": "Chill"
        case "resting": "Rest"
        case "standing": "Let stand:"
        default: "Leave overnight:"
        }
    }

    /// Mixing a sauce or putting things in a bowl ahead of time: the action and an optional suffix.
    static func mixShape(_ masked: String) -> (action: String, suffix: String?)? {
        let mixes = Rx.firstMatch("\\b(whisk together|stir together|mix together|whisk|combine|mix|shake)\\b", in: masked)?[1]
        let container = Rx.firstMatch("\\b(?:put|place|add)\\b[^.;]*?\\b(?:in|into|to) (?:a |the )?((?:small |medium |large |big |shallow |mixing |measuring )?(?:bowl|jug|dish|jar|cup))\\b", in: masked)?[1]
            ?? Rx.firstMatch("\\b(?:to|in|into) (?:a |the )?((?:small |medium |large |big |shallow |mixing |measuring )?(?:bowl|jug|dish|jar|cup))\\b[^.;]*?\\b(?:put|place|add)\\b", in: masked)?[1]
        guard mixes != nil || container != nil else { return nil }
        if let what = Rx.firstMatch("\\b(sauce|slurry|marinade|dressing|glaze)\\b", in: masked)?[1] {
            return ("Mix the \(what):", nil)
        }
        if let mixes { return (RecipeFormatText.capitalisedFirst(mixes), nil) }
        return ("Put", container.map { "in a \($0)" })
    }

    /// Steps that cook: heat, fry, sauté, simmer, boil, bake, roast, grill, sear, broil, cook.
    /// Run on text with ingredient names masked, so "cooking wine" or "fried shallots" don't count;
    /// "stir fry sauce" doesn't either.
    static func isHeat(_ masked: String) -> Bool {
        Rx.test("\\b(?:heat|fry|fries|frying|stir[- ]?fry|saut[eé]\\w*|simmer\\w*|boil|bake|baking|roast\\w*|grill|grilling|sear|searing|broil\\w*|(?<!ready to )cook|cooks)\\b(?!\\s+sauce)", masked)
    }

    /// Replaces each mention with spaces (same length), so names don't trigger word rules.
    static func mask(_ text: String, _ mentions: [StepIngredientLinker.Mention]) -> String {
        let ns = NSMutableString(string: text)
        for m in mentions.sorted(by: { $0.range.location > $1.range.location }) {
            ns.replaceCharacters(in: m.range, with: String(repeating: " ", count: m.range.length))
        }
        return ns as String
    }

    /// Sentence, ";" and "then" clause ranges in a step.
    static func clauseRanges(_ text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        var start = 0
        for m in Rx.re("[.!?](?=\\s|$)|;|,?\\s+(?:and\\s+)?then\\b").matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let end = m.range.location + m.range.length
            if end > start { out.append(NSRange(location: start, length: end - start)) }
            start = end
        }
        if start < ns.length { out.append(NSRange(location: start, length: ns.length - start)) }
        return out.filter { !ns.substring(with: $0).trimmed.isEmpty }
    }

    static func shorten(_ text: String) -> String {
        var t = text.collapsedWhitespace
        if t.count > 60 { t = String(t.prefix(57)).trimmed + "…" }
        return RecipeFormatText.capitalisedFirst(t)
    }

    static func ordered(_ values: [String]) -> [String] {
        var out: [String] = []
        for v in values where !out.contains(v) { out.append(v) }
        return out
    }
}

/// A prep plan as a model describes it: groups of short items naming the ingredients they cover.
public struct ProposedPrepGroup: Hashable, Sendable {
    public var kind: PrepGroupKind
    public var items: [ProposedPrepItem]

    public init(kind: PrepGroupKind, items: [ProposedPrepItem]) {
        self.kind = kind
        self.items = items
    }
}

public struct ProposedPrepItem: Hashable, Sendable {
    public var action: String
    public var ingredients: [String]

    public init(action: String, ingredients: [String]) {
        self.action = action
        self.ingredients = ingredients
    }
}
