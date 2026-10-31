import Foundation

/// A short, natural name for a cook timer, by rules: "Brown the beef", "Simmer the sauce",
/// "Soak the noodles". At most four words; "Step N timer" when the rules aren't sure.
///
/// 1. The cooking verb governing the duration: the last one before it in the sentence (after
///    dropping parentheticals and an "until …" clause), or a purpose after it when the verb is
///    just waiting ("Let it sit for 2 min to brown" → brown; "Wait a few seconds for oil to heat
///    up" → heat the oil). "Bring the mixture to a simmer" → simmer the mixture.
/// 2. Its object: the words right after the verb, else the main food named earlier in the
///    sentence ("Add chicken and stir fry"), else earlier in the step ("Add the noodles. Stir fry
///    for 1 minute."). Foods are ranked protein > noodles/rice > vegetables > aromatics > sauce,
///    so "Pour 1 tbsp of sauce over the chicken, set aside to marinate" → "Marinate the chicken".
///    Two foods read "Cook scallions and garlic"; more become "the vegetables" / "the aromatics".
public enum TimerLabeler {
    /// The longest label, in words ("Stir-fry" is one).
    public static let maximumWords = 4

    /// - Parameters:
    ///   - before: the sentence's text before the duration (since the previous duration in it).
    ///   - after: the sentence's text after the duration.
    ///   - earlier: the step's sentences before this one. When the duration's sentence has no
    ///     verb ("This takes around 3 mins."), the one before it is read instead.
    ///   - step: index into the recipe's steps, for the fallback "Step N timer".
    public static func label(before: String, after: String, earlier: [String], step: Int) -> String {
        let fallback = "Step \(step + 1) timer"
        let context = cleaned(before)
        var verb = lastVerb(in: context)
        var objectText: String?
        var earlierInSentence = context

        if verb == nil || verb?.kind == .wait, let purpose = purpose(in: after) {
            // A waiting verb (or none) gives way to a purpose after the time.
            verb = purpose.verb
            objectText = purpose.object
        } else if let verb {
            // The words right after the verb ("Cook the onion and bell pepper").
            objectText = verb.object ?? directObject(in: context, from: verb.end)
            earlierInSentence = (context as NSString).substring(to: verb.start)
        }
        guard let verb else {
            guard let previous = earlier.last, !Rx.test("[,;:]", before) else { return fallback }
            return label(before: previous, after: "", earlier: Array(earlier.dropLast()), step: step)
        }

        var choices: [String] = []
        if let objectText {
            let found = items(in: objectText)
            if !found.isEmpty {
                choices = phrases(for: found)
            } else if let simple = simpleObject(objectText) {
                choices = ["the \(simple)"]
            }
        }
        if choices.isEmpty {
            // A food named earlier in the sentence, then earlier in the step.
            choices = phrases(for: items(in: earlierInSentence))
            if choices.isEmpty, verb.kind != .rest, verb.kind != .wait {
                choices = phrases(for: items(in: earlier.joined(separator: " ")))
            }
        }

        func compose(_ obj: String?) -> String? {
            switch (verb.kind, obj) {
            case (.wait, nil): return nil
            case (.wait, let o?), (.intransitive, let o?): return "Let \(o) \(verb.display.lowercased())"
            case (.intransitive, nil): return "Let it \(verb.display.lowercased())"
            case (_, let o?): return "\(verb.display) \(o)"
            case (_, nil): return verb.display
            }
        }
        for choice in choices {
            if let text = compose(choice), text.split(separator: " ").count <= maximumWords { return text }
        }
        // A bare verb only when it says something by itself ("Simmer", "Rest"), not "Cook".
        if verb.kind == .wait || genericVerbs.contains(verb.display) { return fallback }
        return compose(nil) ?? fallback
    }

    // MARK: Verbs

    enum VerbKind { case active, rest, wait, intransitive }

    struct Verb {
        var display: String
        var kind: VerbKind
        /// NSString range of the match in the context.
        var start: Int
        var end: Int
        /// "Bring the mixture to a simmer": the object, already found.
        var object: String?
    }

    /// Base forms only, so "boils", "browning" and "cooking oil" don't count. Longest first.
    static let verbs: [(pattern: String, display: String, kind: VerbKind)] = [
        ("stir[- ]?fry", "Stir-fry", .active), ("deep[- ]fry", "Deep-fry", .active), ("pan[- ]fry", "Pan-fry", .active),
        ("shallow[- ]fry", "Fry", .active), ("set aside", "Set aside", .wait),
        ("simmer", "Simmer", .active), ("boil", "Boil", .active), ("cook", "Cook", .active), ("fry", "Fry", .active),
        ("sear", "Sear", .active), ("brown", "Brown", .active), ("bake", "Bake", .active), ("roast", "Roast", .active),
        ("marinate", "Marinate", .active), ("soak", "Soak", .active), ("steam", "Steam", .active),
        ("blanch", "Blanch", .active), ("braise", "Braise", .active), ("toss", "Toss", .active), ("stir", "Stir", .active),
        ("saut[eé]", "Sauté", .active), ("reduce", "Reduce", .active), ("whisk", "Whisk", .active),
        ("knead", "Knead", .active), ("proof|prove", "Proof", .active), ("grill", "Grill", .active),
        ("broil", "Broil", .active), ("poach", "Poach", .active), ("toast", "Toast", .active),
        ("carameli[sz]e", "Caramelize", .active), ("wilt", "Wilt", .active), ("mix", "Mix", .active),
        ("beat", "Beat", .active), ("blend", "Blend", .active), ("microwave", "Microwave", .active),
        ("heat", "Heat", .active), ("char", "Char", .active), ("sweat", "Sweat", .active), ("melt", "Melt", .active),
        ("steep", "Steep", .active), ("bloom", "Bloom", .active),
        ("rest", "Rest", .rest), ("cool", "Cool", .rest), ("chill|refrigerate", "Chill", .rest), ("freeze", "Freeze", .rest),
        ("sit", "Sit", .wait), ("stand", "Stand", .wait), ("wait", "Wait", .wait), ("leave", "Leave", .wait),
        ("rise", "Rise", .intransitive),
    ]

    /// Too vague without an object.
    static let genericVerbs: Set<String> = ["Cook", "Heat", "Mix", "Stir", "Beat", "Blend", "Whisk", "Fry", "Microwave"]

    /// A word before a lexicon match that makes it a noun: "the heat", "to a boil", "medium heat".
    static let nounMarkers: Set<String> = ["the", "a", "an", "medium", "high", "low", "gentle", "rolling", "full",
                                           "over", "on", "of", "your", "its", "light", "dark", "this", "that"]

    static func lastVerb(in context: String) -> Verb? {
        let ns = context as NSString
        var claimed: [NSRange] = []
        var found: [Verb] = []
        // "Bring the mixture (back) up to a simmer": simmer the mixture.
        let bring = "\\bbring\\s+((?:(?!\\bto\\b)[\\w'’ -])*?)\\s*(?:\\bback\\s+)?(?:\\bup\\s+)?\\bto\\s+(?:an?\\s+)?(?:gentle\\s+|rolling\\s+|low\\s+|full\\s+)?(boil|simmer)\\b"
        for m in Rx.re(bring).matches(in: context, range: NSRange(location: 0, length: ns.length)) {
            let what = m.range(at: 1).length > 0 ? ns.substring(with: m.range(at: 1)) : ""
            let display = ns.substring(with: m.range(at: 2)).lowercased() == "boil" ? "Boil" : "Simmer"
            found.append(Verb(display: display, kind: .active, start: m.range.location,
                              end: m.range.location + m.range.length, object: what))
            claimed.append(m.range)
        }
        for entry in verbs {
            for m in Rx.re("\\b(?:\(entry.pattern))\\b").matches(in: context, range: NSRange(location: 0, length: ns.length)) {
                guard !claimed.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) else { continue }
                let previous = ns.substring(to: m.range.location).split(whereSeparator: { !$0.isLetter }).last.map { $0.lowercased() }
                if let previous, nounMarkers.contains(previous) { continue }
                let next = ns.substring(from: m.range.location + m.range.length).split(whereSeparator: { !$0.isLetter }).first?.lowercased()
                if entry.display == "Brown", next == "sugar" || next == "rice" { continue }
                claimed.append(m.range)
                found.append(Verb(display: entry.display, kind: entry.kind, start: m.range.location,
                                  end: m.range.location + m.range.length, object: nil))
            }
        }
        return found.max { $0.start < $1.start }
    }

    /// "to brown", "so it can rest", "for oil to heat up" after the duration.
    static func purpose(in after: String) -> (verb: Verb, object: String?)? {
        let text = String(after.prefix { $0 != "." && $0 != ")" && $0 != ";" })
        func verb(_ word: String) -> Verb? {
            guard let v = lastVerb(in: word), v.start == 0 else { return nil }
            return Verb(display: v.display, kind: v.kind, start: 0, end: 0, object: nil)
        }
        if let m = Rx.firstMatch("^\\W*(?:total\\W*)?(?:or so\\W*)?(?:to|so (?:it|they) can)\\s+([a-z]+(?:[- ]fry)?)", in: text),
           let word = m[1], let v = verb(word), v.kind != .wait {
            return (v, nil)
        }
        if let m = Rx.firstMatch("^\\s*for\\s+(?:the\\s+)?([a-z ]+?)\\s+to\\s+([a-z]+)", in: text),
           let object = m[1], let word = m[2], let v = verb(word), v.kind != .wait {
            return (v, object)
        }
        return nil
    }

    // MARK: Text

    /// The text before the duration with parentheticals and "until …" dropped. When the duration
    /// sits inside brackets ("(soak in boiled water for 1 minute)"), the bracket's words stay.
    static func cleaned(_ before: String) -> String {
        var s = Rx.replace("\\([^()]*\\)", in: before, with: " ")
        s = s.replacingOccurrences(of: "(", with: " ")
        s = Rx.replace("\\b(?:or\\s+)?(?:until|till)\\b.*$", in: s, with: "")
        return s
    }

    /// The words right after the verb, up to a preposition or punctuation.
    static func directObject(in context: String, from location: Int) -> String {
        let rest = (context as NSString).substring(from: location)
        let stop = "\\b(?:for|about|around|until|in|on|over|with|to|at|from|into|under|while|then|so|before|after|uncovered|covered|stirring|tossing|according)\\b|[,;:.(\\-–—*]"
        guard let range = Rx.re(stop).firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length))?.range else {
            return rest.trimmed
        }
        return (rest as NSString).substring(to: range.location).trimmed
    }

    static let fillerWords: Set<String> = [
        "a", "an", "the", "some", "all", "remaining", "your", "each", "more", "of", "it", "them", "everything",
        "through", "well", "gently", "constantly", "briefly", "occasionally", "together", "up", "down", "off", "out",
        "again", "both", "sides", "side", "and", "or", "lid", "pan", "pot", "wok", "heat",
    ]

    /// An unrecognised object of one or two words: "the stew", "the oil".
    static func simpleObject(_ text: String) -> String? {
        let firstPart = Rx.replace("\\b(?:and|or)\\b.*$", in: text, with: "")
        let words = firstPart.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            .filter { !fillerWords.contains($0) && !Rx.test("^(?:tbsp|tsp|cups?|g|kg|ml|l|lbs?|oz|pinch|handful|slices?|pieces?)$", $0) }
        guard (1...2).contains(words.count), words.allSatisfy({ $0.count >= 3 }) else { return nil }
        return words.joined(separator: " ")
    }

    // MARK: Foods

    struct Item: Equatable {
        var display: String
        /// 0 protein, 1 noodles/rice/dough, 2 vegetables, 3 aromatics, 4 sauce, 5 mixture.
        var rank: Int
        var location: Int
    }

    /// Longest first; rank -1 claims seasonings so "soy sauce" isn't "sauce" and "chicken stock"
    /// isn't chicken.
    static let foods: [(pattern: String, display: String, rank: Int)] = [
        ("(?:soy|oyster|fish|hoisin|chil+i|hot|worcestershire|stir[- ]fry|black bean|light|dark|bean|sweet chil+i) sauces?", "", -1),
        ("chil+i (?:oil|flakes|powder|paste|crisp)", "", -1), ("lao gan ma", "", -1),
        ("(?:chicken|beef|vegetable|pork) (?:stock|broth|bouillon|powder)", "", -1),
        ("(?:garlic|ginger|onion) (?:powder|salt)", "", -1), ("rice (?:vinegar|wine)", "", -1),
        ("(?:white|black) pepper", "", -1), ("cooking wine|shaoxing wine|baking soda|bean paste", "", -1),
        ("pork belly", "pork belly", 0),
        ("(?:ground|minced) beef|beef mince|beef", "beef", 0),
        ("(?:ground|minced) chicken|chicken", "chicken", 0),
        ("(?:ground|minced) pork|pork mince|pork", "pork", 0),
        ("lamb", "lamb", 0), ("shrimps?", "shrimp", 0), ("prawns?", "prawns", 0), ("tofu", "tofu", 0),
        ("salmon", "salmon", 0), ("fish", "fish", 0), ("steaks?", "steak", 0), ("duck", "duck", 0),
        ("turkey", "turkey", 0), ("sausages?", "sausages", 0), ("bacon", "bacon", 0), ("meat", "meat", 0),
        ("(?:rice|egg|chow mein|udon|soba) noodles|noodles", "noodles", 1), ("eggs?", "eggs", 0),
        ("rice", "rice", 1), ("pasta|spaghetti", "pasta", 1), ("dough", "dough", 1), ("batter", "batter", 1),
        ("potato(?:es)?", "potatoes", 1), ("dumplings", "dumplings", 1),
        ("bean ?sprouts", "bean sprouts", 2), ("green beans", "green beans", 2), ("bok choy|pak choi", "bok choy", 2),
        ("scallions?|green onions?|spring onions?|shallots?", "scallions", 3),
        ("cabbage", "cabbage", 2), ("carrots?", "carrot", 2), ("bell peppers?|capsicums?", "pepper", 2),
        ("onions?", "onion", 2), ("broccoli", "broccoli", 2), ("mushrooms?", "mushrooms", 2),
        ("spinach", "spinach", 2), ("peas", "peas", 2), ("zucchinis?|courgettes?", "zucchini", 2),
        ("tomato(?:es)?", "tomatoes", 2), ("celery", "celery", 2), ("eggplants?|aubergines?", "eggplant", 2),
        ("corn", "corn", 2), ("kale", "kale", 2), ("vegetables|veggies|veg", "vegetables", 2),
        ("garlic", "garlic", 3), ("ginger", "ginger", 3),
        ("(?:dried |red |green |fresh )?chil+i(?:e?s)?(?: peppers?)?", "chilies", 3),
        ("(?:sichuan )?peppercorns?", "peppercorns", 3), ("spices?", "spices", 3), ("aromatics", "aromatics", 3),
        ("sauce", "sauce", 4), ("glaze", "glaze", 4), ("stock|broth", "stock", 4),
        ("mixture", "mixture", 5),
    ]

    static func items(in text: String) -> [Item] {
        let ns = text as NSString
        var claimed: [NSRange] = []
        var out: [Item] = []
        for food in foods {
            for m in Rx.re("\\b(?:\(food.pattern))\\b").matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard !claimed.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) else { continue }
                claimed.append(m.range)
                if food.rank >= 0 { out.append(Item(display: food.display, rank: food.rank, location: m.range.location)) }
            }
        }
        return out.sorted { $0.location < $1.location }
    }

    /// Object phrases to try, best first: "the beef"; "scallions and garlic", then "the aromatics".
    static func phrases(for items: [Item]) -> [String] {
        guard let best = items.map(\.rank).min() else { return [] }
        var names: [String] = []
        for item in items where item.rank == best && !names.contains(item.display) { names.append(item.display) }
        let group = best == 2 ? "vegetables" : best == 3 ? "aromatics" : nil
        if let group, names.contains(group) { return ["the \(group)"] }
        switch names.count {
        case 1: return ["the \(names[0])"]
        case 2: return ["\(names[0]) and \(names[1])", group.map { "the \($0)" } ?? "the \(names[0])"]
        default: return [group.map { "the \($0)" } ?? "the \(names[0])"]
        }
    }
}
