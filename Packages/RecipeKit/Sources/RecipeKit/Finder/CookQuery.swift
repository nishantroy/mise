import Foundation

/// A taste or style the cook asked for ("something spicy", "noodles", "comforting").
public enum CookStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case spicy, light, comforting, noodles, soup, rice, stirFry, curry

    public var label: String {
        switch self {
        case .stirFry: "stir-fry"
        default: rawValue
        }
    }
}

/// An ingredient named in a "What can I cook?" question.
public struct QueryIngredient: Codable, Hashable, Sendable {
    /// The words the cook used, lowercased ("ground beef", "broccoli").
    public var term: String
    /// Catalog entry the words map to, when there is one.
    public var catalogID: String?
    /// "Some sad broccoli", "leftover chicken", "use up the spinach": weighted higher.
    public var useUp: Bool

    public init(term: String, catalogID: String?, useUp: Bool = false) {
        self.term = term
        self.catalogID = catalogID
        self.useUp = useUp
    }

    /// Catalog ID, or the term for words the catalog doesn't know.
    public var key: String { catalogID ?? term }
}

/// What the cook asked for, parsed from free text (typed or dictated).
public struct CookQuery: Codable, Hashable, Sendable {
    public var text: String
    /// Ingredients they have or want to use.
    public var ingredients: [QueryIngredient] = []
    /// "No pork", "without mushrooms": hard filter.
    public var avoid: [QueryIngredient] = []
    /// "Vegetarian", "no meat", "dairy free": hard filter on catalog tags.
    public var avoidTags: Set<IngredientTag> = []
    /// "I'm out of eggs": counted as missing from the pantry.
    public var missing: [QueryIngredient] = []
    /// Upper time limit in minutes ("under 30 min", or `quickMinutes` for "quick").
    public var maxMinutes: Int?
    /// The limit came from a word like "quick" rather than a number.
    public var maxFromQuickWord: Bool = false
    /// Cuisines from `CuisineGuesser.vocabulary`.
    public var cuisines: [String] = []
    public var styles: [CookStyle] = []
    /// "Not spicy", "nothing heavy" (as `light`, see the parser): a soft penalty.
    public var avoidStyles: [CookStyle] = []
    /// Leftover words, matched against recipe titles ("pancakes", "mongolian").
    public var keywords: [String] = []
    public var servings: Int?
    /// "With what I have": only recipes the pantry covers (known swaps allowed).
    public var pantryOnly: Bool = false

    public init(text: String) {
        self.text = text
    }

    /// Something that makes a recipe a better or worse match (not just a filter).
    public var hasPositiveCriteria: Bool {
        !ingredients.isEmpty || !cuisines.isEmpty || !styles.isEmpty || !keywords.isEmpty
    }

    public var hasFilters: Bool {
        !avoid.isEmpty || !avoidTags.isEmpty || maxMinutes != nil || pantryOnly
    }

    /// Short chips describing what was understood: "chicken", "use up broccoli", "no pork",
    /// "under 30 min", "Chinese", "spicy", "for 4", "with what you have".
    public var summary: [String] {
        var out: [String] = []
        out += ingredients.map { $0.useUp ? "use up \($0.term)" : $0.term }
        out += cuisines
        out += styles.map(\.label)
        out += keywords.map { "“\($0)”" }
        if let maxMinutes { out.append("under \(CookFinderFormat.duration(maxMinutes))") }
        out += avoid.map { "no \($0.term)" }
        out += CookQueryParser.tagSummary(avoidTags)
        out += avoidStyles.map { $0 == .spicy ? "not spicy" : "not \($0.label)" }
        out += missing.map { "out of \($0.term)" }
        if let servings { out.append("for \(servings)") }
        if pantryOnly { out.append("with what you have") }
        return out
    }
}

/// Rules that turn "i have chicken and some sad broccoli something quick no pork" into a
/// `CookQuery`. Works on words, not punctuation, so dictated run-ons parse like typed text.
///
/// Order: phrases first (pantry-only, time limits, servings, "quick"), then catalog ingredients
/// (longest alias first, so "ground beef" beats "beef"), then cuisine, style and diet words.
/// Negation ("no", "without", "don't want", postfix "free") covers the items that follow it,
/// joined only by "and / or / , / the / any…", so "no pork or beef and something spicy"
/// avoids both meats but still wants spicy. Anything left that isn't a stopword is a title keyword.
public struct CookQueryParser: Sendable {
    /// Minutes a "quick" / "fast" / "weeknight" request means.
    public static let quickMinutes = 30

    public let catalog: IngredientCatalog
    private let aliasesByFirstWord: [String: [(words: [String], id: String)]]

    public init(catalog: IngredientCatalog = .shared) {
        self.catalog = catalog
        var table: [String: [(words: [String], id: String)]] = [:]
        for (alias, id) in catalog.aliases {
            let words = alias.split(separator: " ").map(String.init)
            guard let first = words.first else { continue }
            table[first, default: []].append((words, id))
        }
        for key in table.keys { table[key]?.sort { $0.words.count > $1.words.count } }
        aliasesByFirstWord = table
    }

    // MARK: Tokens

    struct Token {
        /// Lowercased, folded, apostrophes removed ("don't" → "dont").
        var word: String
        /// `word` with the catalog's light singular ("noodles" → "noodle").
        var norm: String
        /// A clause break (",", ".", "?", newline…).
        var isBreak: Bool
    }

    static func tokenize(_ text: String) -> [Token] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        let chars = Array(folded)
        var out = ""
        for (i, c) in chars.enumerated() {
            if c == "'" || c == "’" || c == "‘" { continue }
            if c == ".", i > 0, i + 1 < chars.count, chars[i - 1].isNumber, chars[i + 1].isNumber {
                out.append(c)
            } else if c.isLetter || c.isNumber {
                out.append(c)
            } else if ",.;:!?\n\r()".contains(c) {
                out += " , "
            } else {
                out.append(" ")
            }
        }
        return out.split(separator: " ").map { piece in
            let w = String(piece)
            return w == "," ? Token(word: ",", norm: ",", isBreak: true)
                            : Token(word: w, norm: IngredientCatalog.singular(w), isBreak: false)
        }
    }

    // MARK: Vocabulary

    static let minimumCues: Set<String> = ["over", "least", "longer", "more"]
    static let limitCueWords: Set<String> = ["under", "less", "than", "no", "more", "within", "in", "max", "maximum", "at", "most", "up", "to", "tops", "about", "around", "like", "below", "only", "takes", "take"]
    static let quickWords: Set<String> = ["quick", "quickly", "fast", "speedy", "hurry", "rush", "rushed", "weeknight", "asap", "quickie"]
    static let quickPhrases: [[String]] = [["short", "on", "time"], ["not", "much", "time"], ["no", "time"], ["little", "time"], ["in", "a", "pinch"]]

    static let pantryPhrases: [[String]] = [
        ["with", "what", "i", "have"], ["with", "what", "i", "got"], ["with", "what", "ive", "got"],
        ["what", "i", "have"], ["what", "i", "already", "have"], ["what", "ive", "got"], ["what", "i", "got"],
        ["whatever", "i", "have"], ["whatever", "ive", "got"], ["what", "we", "have"], ["what", "weve", "got"],
        ["whats", "in", "my"], ["whats", "in", "the"], ["what", "is", "in", "my"], ["what", "is", "in", "the"],
        ["from", "my", "pantry"], ["from", "the", "pantry"], ["from", "my", "fridge"], ["just", "my", "pantry"],
        ["without", "shopping"], ["no", "shopping"], ["without", "going", "shopping"], ["without", "going", "to", "the", "store"],
        ["without", "going", "to", "the", "shop"], ["no", "grocery"], ["dont", "want", "to", "shop"],
        ["dont", "want", "to", "go", "shopping"], ["dont", "want", "to", "go", "to", "the", "store"],
        ["pantry", "only"], ["already", "have"],
    ]

    /// Start a negated run: the items that follow are avoided.
    static let negationCues: [[String]] = [
        ["no"], ["not"], ["without"], ["avoid"], ["avoiding"], ["except"], ["minus"], ["skip"], ["hold", "the"],
        ["nothing", "with"], ["nothing"], ["dont", "want"], ["do", "not", "want"], ["dont", "like"], ["hate"],
        ["allergic", "to"], ["cant", "have"], ["cant", "eat"], ["sick", "of"], ["tired", "of"], ["but", "not"],
        ["isnt"], ["not", "too"], ["anything", "but"], ["everything", "but"], ["other", "than"],
    ]
    /// Start a "missing" run: "I'm out of eggs".
    static let missingCues: [[String]] = [
        ["out", "of"], ["ran", "out", "of"], ["run", "out", "of"], ["all", "out", "of"], ["dont", "have"],
        ["dont", "have", "any"], ["no", "more"], ["havent", "got"], ["do", "not", "have"],
    ]
    /// Start a "use up" run: "use up the spinach".
    static let useUpCues: [[String]] = [
        ["use", "up"], ["using", "up"], ["get", "rid", "of"], ["finish", "off"], ["finish", "up"],
        ["need", "to", "use"], ["have", "to", "use"], ["want", "to", "use"], ["use", "the"],
    ]
    /// After an ingredient: "broccoli that's going off", "chicken to use up".
    static let useUpSuffixes: [[String]] = [
        ["going", "off"], ["going", "bad"], ["about", "to", "go"], ["before", "it", "goes"], ["to", "use", "up"],
        ["that", "needs", "using"], ["needs", "using"], ["needs", "to", "be", "used"], ["thats", "going", "off"],
        ["before", "they", "go"], ["go", "bad"], ["goes", "bad"], ["going", "soft"],
    ]
    static let useUpAdjectives: Set<String> = ["sad", "leftover", "leftovers", "wilting", "wilted", "limp", "old", "extra", "spare", "aging", "ageing", "tired"]
    /// Words that keep a negated / use-up run going between items.
    static let connectors: Set<String> = ["and", "or", "nor", "any", "the", "too", "very", "either", "also", "a", "an", "some", "much", "my", "that", "so", "overly", "really", "of", "more", "anything", "with", "in", "it"]

    static let styleWords: [String: CookStyle] = [
        "spicy": .spicy, "spice": .spicy, "hot": .spicy, "heat": .spicy, "fiery": .spicy, "kick": .spicy, "chili": .spicy,
        "chilli": .spicy, "chile": .spicy, "mala": .spicy, "numbing": .spicy, "spicier": .spicy,
        "light": .light, "lighter": .light, "healthy": .light, "healthier": .light, "fresh": .light, "lean": .light, "salad": .light,
        "comforting": .comforting, "comfort": .comforting, "cozy": .comforting, "cosy": .comforting, "hearty": .comforting,
        "warming": .comforting, "stew": .comforting, "stewy": .comforting, "braise": .comforting, "braised": .comforting,
        "filling": .comforting, "homey": .comforting, "indulgent": .comforting, "warm": .comforting,
        "noodle": .noodles, "ramen": .noodles, "udon": .noodles, "soba": .noodles, "pho": .noodles,
        "soup": .soup, "soupy": .soup, "broth": .soup, "brothy": .soup,
        "stirfry": .stirFry, "wok": .stirFry,
        "curry": .curry, "currie": .curry,
    ]
    static let stylePhrases: [([String], CookStyle)] = [
        (["stir", "fry"], .stirFry), (["stir", "fried"], .stirFry), (["fried", "rice"], .rice), (["rice", "bowl"], .rice),
        (["low", "cal"], .light), (["low", "calorie"], .light),
    ]
    /// Positive they mean comforting; negated ("nothing heavy") they mean light.
    static let heavyWords: Set<String> = ["heavy", "rich", "greasy", "oily", "stodgy"]

    /// Diet words: positive ones apply on their own; tag words only when negated or before "free".
    static let dietWords: [String: Set<IngredientTag>] = [
        "vegetarian": SwapEngine.forbiddenTags(for: .vegetarian), "veggie": SwapEngine.forbiddenTags(for: .vegetarian),
        "meatless": SwapEngine.forbiddenTags(for: .vegetarian), "vegan": SwapEngine.forbiddenTags(for: .vegan),
        "pescatarian": SwapEngine.forbiddenTags(for: .pescatarian),
    ]
    static let tagWords: [String: Set<IngredientTag>] = [
        "meat": [.meat, .pork, .beef, .poultry], "seafood": [.fish, .shellfish], "shellfish": [.shellfish],
        "dairy": [.dairy], "gluten": [.gluten], "wheat": [.gluten], "nut": [.nuts], "alcohol": [.alcohol],
        "booze": [.alcohol], "soy": [.soy], "poultry": [.poultry],
    ]

    /// Cuisine names ("thai", "sichuan", "middle eastern") from the guesser's title keywords, plus "asian".
    static let cuisineWords: [([String], [String])] = {
        var out: [([String], [String])] = CuisineGuesser.titleKeywords.filter { $0.weight >= 6 }
            .map { ($0.normalised.split(separator: " ").map(String.init), [$0.cuisine]) }
        out.append((["asian"], ["Chinese", "Japanese", "Korean", "Thai"]))
        return out.sorted { $0.0.count > $1.0.count }
    }()

    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "i", "im", "ive", "id", "me", "my", "we", "us", "our", "you", "your",
        "it", "its", "is", "are", "am", "be", "was", "were", "been", "have", "has", "had", "got", "get", "do", "does",
        "did", "can", "could", "would", "should", "will", "shall", "might", "may", "must", "what", "whats", "which",
        "that", "thats", "this", "these", "those", "there", "here", "with", "without", "for", "from", "in", "on", "at",
        "to", "of", "by", "up", "out", "off", "into", "over", "under", "about", "around", "than", "then", "less", "more",
        "most", "some", "any", "all", "just", "only", "really", "very", "pretty", "kind", "kinda", "sort", "like",
        "maybe", "please", "um", "uh", "uhm", "hmm", "ok", "okay", "well", "also", "too", "make", "making", "cook",
        "cooking", "eat", "eating", "want", "wanna", "need", "feel", "feeling", "craving", "crave", "fancy", "something",
        "anything", "thing", "things", "stuff", "dinner", "lunch", "breakfast", "supper", "meal", "meals", "dish",
        "dishes", "recipe", "recipes", "food", "tonight", "today", "tomorrow", "night", "now", "week", "good",
        "nice", "great", "tasty", "delicious", "easy", "simple", "minute", "minutes", "min", "mins", "hour", "hours",
        "hr", "hrs", "time", "max", "maximum", "tops", "within", "below", "people", "person", "persons", "serve",
        "serves", "serving", "servings", "feed", "feeds", "family", "guests", "lot", "lots", "bit", "little",
        "how", "where", "when", "why", "who", "use", "using", "used", "left", "leftover", "fridge", "pantry",
        "home", "house", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "half",
        "else", "other", "another", "new", "different", "same", "mood", "sounds", "sound", "go", "going", "let", "lets",
        "free", "dont", "not", "no", "nothing", "isnt", "too", "much", "many", "few", "couple", "bunch", "handful",
        "bowl", "plate", "side", "sides", "main", "whole", "big", "small", "large", "think", "know", "say", "said",
        "hey", "hi", "mise", "suggest", "suggestion", "ideas", "idea", "option", "options", "help", "find", "show",
        "give", "tell", "best", "match", "sad", "old", "extra", "spare", "wilting", "wilted", "limp", "quick", "fast",
        "already", "still", "ready", "done", "able", "possible", "if", "while", "after", "before", "until",
        "they", "them", "bad", "cold", "night", "weekend", "rainy", "winter", "summer", "day", "evening", "morning",
        "thats", "whats", "theres", "lazy", "sunday", "work", "kids", "boyfriend", "girlfriend", "wife", "husband",
        "friends", "everyone", "looking", "looks", "take", "takes", "taking", "quite", "probably", "definitely", "actually", "honestly", "basically", "ish",
    ]

    // MARK: Parse

    private enum Item {
        case ingredient(QueryIngredient)
        case style(CookStyle)
        case heavy
        case tags(Set<IngredientTag>)
        case diet(Set<IngredientTag>)
        case cuisine([String])
    }

    private enum Slot {
        case free
        case used
        case brk
        case connector
        case negate
        case missing
        case useUp
        case item(Item, length: Int)
    }

    public func parse(_ text: String) -> CookQuery {
        var query = CookQuery(text: text)
        let tokens = Self.tokenize(text)
        let words = tokens.map(\.word)
        let norms = tokens.map(\.norm)
        var slots: [Slot] = tokens.map { $0.isBreak ? .brk : .free }

        func isFree(_ range: Range<Int>) -> Bool {
            range.upperBound <= slots.count && range.allSatisfy { if case .free = slots[$0] { true } else { false } }
        }
        func has(_ phrase: [String], at i: Int) -> Bool {
            i + phrase.count <= words.count && isFree(i..<(i + phrase.count)) && Array(words[i..<(i + phrase.count)]) == phrase
        }
        func mark(_ range: Range<Int>, _ slot: Slot = .used) {
            for j in range { slots[j] = .used }
            if case .used = slot {} else { slots[range.lowerBound] = slot }
        }

        // 1. Pantry-only phrases.
        for phrase in Self.pantryPhrases.sorted(by: { $0.count > $1.count }) {
            for i in words.indices where has(phrase, at: i) {
                query.pantryOnly = true
                mark(i..<(i + phrase.count))
            }
        }

        // 2. Time limits and servings.
        var i = 0
        while i < words.count {
            guard case .free = slots[i] else { i += 1; continue }
            if let (minutes, length) = Self.duration(words, at: i) {
                let before = i > 0 ? words[i - 1] : ""
                let before2 = i > 1 ? words[i - 2] : ""
                let before3 = i > 2 ? words[i - 3] : ""
                let isMinimum = Self.minimumCues.contains(before) && before2 != "no"
                    || (before == "than" && ["more", "longer"].contains(before2) && before3 != "no")
                var start = i
                if !isMinimum, minutes > 0 {
                    query.maxMinutes = min(query.maxMinutes ?? Int.max, minutes)
                    // Swallow "no more than", "less than", "under", "at most" so they don't read as cues.
                    while start > 0, Self.limitCueWords.contains(words[start - 1]), isFree((start - 1)..<start) { start -= 1 }
                }
                mark(start..<(i + length))
                i += length
                continue
            }
            // "under 30", "in 20" with no unit.
            if ["under", "within", "in", "below"].contains(words[i]), i + 1 < words.count,
               let (n, length) = Self.number(words, at: i + 1), n >= 5, n <= 240, !Self.isServingsWord(words, at: i + 1 + length) {
                query.maxMinutes = min(query.maxMinutes ?? Int.max, Int(n))
                mark(i..<(i + 1 + length))
                i += 1 + length
                continue
            }
            if let (servings, length) = Self.servings(words, at: i) {
                query.servings = servings
                mark(i..<(i + length))
                i += length
                continue
            }
            i += 1
        }

        // 3. "Quick" words, unless negated ("no rush").
        for phrase in Self.quickPhrases {
            for j in words.indices where has(phrase, at: j) {
                if query.maxMinutes == nil { query.maxMinutes = Self.quickMinutes; query.maxFromQuickWord = true }
                mark(j..<(j + phrase.count))
            }
        }
        for j in words.indices where isFree(j..<(j + 1)) && Self.quickWords.contains(words[j]) {
            // "no rush", "not in a hurry": not a limit, and the "no" mustn't negate what follows.
            let negator = (max(0, j - 3)..<j).last { ["no", "not"].contains(words[$0]) }
            if negator == nil, query.maxMinutes == nil {
                query.maxMinutes = Self.quickMinutes
                query.maxFromQuickWord = true
            }
            mark((negator ?? j)..<(j + 1))
        }

        // 4. Cues (longest first so "dont have" isn't read as "dont want").
        let cues: [([String], Slot)] = (Self.missingCues.map { ($0, Slot.missing) } + Self.negationCues.map { ($0, Slot.negate) }
            + Self.useUpCues.map { ($0, Slot.useUp) }).sorted { $0.0.count > $1.0.count }
        // Catalog ingredients first would swallow "no" in nothing, but cues must not swallow
        // ingredient words ("use the" is fine; no alias starts with a cue word we use).
        for j in words.indices {
            for (phrase, slot) in cues where has(phrase, at: j) {
                mark(j..<(j + phrase.count), slot)
                break
            }
        }

        // 5. Catalog ingredients, longest alias first at each position.
        var j = 0
        while j < norms.count {
            guard case .free = slots[j], let candidates = aliasesByFirstWord[norms[j]] else { j += 1; continue }
            var matched = false
            for (aliasWords, id) in candidates where j + aliasWords.count <= norms.count {
                let range = j..<(j + aliasWords.count)
                guard isFree(range), Array(norms[range]) == aliasWords else { continue }
                let term = words[range].joined(separator: " ")
                let item: Item = id == "rice" && aliasWords.count == 1 ? .style(.rice)
                    : .ingredient(QueryIngredient(term: term, catalogID: id))
                mark(range)
                slots[j] = .item(item, length: aliasWords.count)
                j += aliasWords.count
                matched = true
                break
            }
            if !matched { j += 1 }
        }

        // 6. Cuisine, style and diet words.
        for (phrase, cuisines) in Self.cuisineWords {
            for k in norms.indices where k + phrase.count <= norms.count && isFree(k..<(k + phrase.count)) && Array(norms[k..<(k + phrase.count)]) == phrase {
                mark(k..<(k + phrase.count))
                slots[k] = .item(.cuisine(cuisines), length: phrase.count)
            }
        }
        for (phrase, style) in Self.stylePhrases {
            for k in norms.indices where k + phrase.count <= norms.count && isFree(k..<(k + phrase.count)) && Array(norms[k..<(k + phrase.count)]) == phrase {
                mark(k..<(k + phrase.count))
                slots[k] = .item(.style(style), length: phrase.count)
            }
        }
        if let k = words.indices.first(where: { has(["plant", "based"], at: $0) }) {
            mark(k..<(k + 2))
            slots[k] = .item(.diet(SwapEngine.forbiddenTags(for: .vegan)), length: 2)
        }
        for k in norms.indices where isFree(k..<(k + 1)) {
            if norms[k] == "fresh", k + 1 < slots.count, case .item(.ingredient, _) = slots[k + 1] {
                slots[k] = .used // "fresh basil" is an ingredient, not a request for something light
            } else if let style = Self.styleWords[norms[k]] {
                slots[k] = .item(.style(style), length: 1)
            } else if Self.heavyWords.contains(norms[k]) {
                slots[k] = .item(.heavy, length: 1)
            } else if let tags = Self.dietWords[norms[k]] {
                slots[k] = .item(.diet(tags), length: 1)
            } else if let tags = Self.tagWords[norms[k]] {
                slots[k] = .item(.tags(tags), length: 1)
            } else if Self.connectors.contains(words[k]) {
                slots[k] = .connector
            }
        }

        // 7. Walk the slots: cues set a mode that carries across connectors to the next items.
        enum Mode { case want, negate, missing, useUp }
        var mode = Mode.want
        var k = 0
        while k < slots.count {
            switch slots[k] {
            case .negate: mode = .negate
            case .missing: mode = .missing
            case .useUp: mode = .useUp
            case .connector, .used: break
            case .brk:
                // A comma keeps a negated list going only into another ingredient ("no pork, beef or lamb").
                if mode != .want, !Self.nextIsIngredient(slots, after: k) { mode = .want }
            case .free:
                let word = words[k]
                if Self.useUpAdjectives.contains(word) || word == "some" {
                    break
                }
                mode = .want
            case .item(let item, let length):
                let followedByFree = k + length < words.count && words[k + length] == "free"
                let effective: Mode = followedByFree ? .negate : mode
                switch item {
                case .ingredient(var ing):
                    let adjective = (max(0, k - 2)..<k).contains { Self.useUpAdjectives.contains(words[$0]) }
                    let suffix = Self.useUpSuffixes.contains { phrase in
                        k + length + phrase.count <= words.count && Array(words[(k + length)..<(k + length + phrase.count)]) == phrase
                    }
                    switch effective {
                    case .negate: Self.add(ing, to: &query.avoid)
                    case .missing: Self.add(ing, to: &query.missing)
                    case .want, .useUp:
                        ing.useUp = effective == .useUp || adjective || suffix
                        Self.add(ing, to: &query.ingredients)
                    }
                case .style(let style):
                    if effective == .negate {
                        if !query.avoidStyles.contains(style) { query.avoidStyles.append(style) }
                    } else if !query.styles.contains(style) {
                        query.styles.append(style)
                    }
                case .heavy:
                    let style: CookStyle = effective == .negate ? .light : .comforting
                    if !query.styles.contains(style) { query.styles.append(style) }
                case .tags(let tags):
                    if effective == .negate { query.avoidTags.formUnion(tags) }
                case .diet(let tags):
                    query.avoidTags.formUnion(tags)
                case .cuisine(let cuisines):
                    if effective != .negate {
                        for c in cuisines where !query.cuisines.contains(c) { query.cuisines.append(c) }
                    }
                }
                // Styles and cuisines don't carry a negation across a comma; ingredients do (above).
                k += length
                if followedByFree { k += 1 }
                continue
            }
            k += 1
        }

        // A word both wanted and avoided: the avoid wins.
        let avoided = Set(query.avoid.map(\.key))
        query.ingredients.removeAll { avoided.contains($0.key) }
        query.styles.removeAll { query.avoidStyles.contains($0) }

        // 8. Keywords: whatever's left that isn't filler.
        for (idx, slot) in slots.enumerated() {
            guard case .free = slot else { continue }
            let w = words[idx]
            guard w.count >= 3, !Self.stopwords.contains(w), !Self.stopwords.contains(norms[idx]),
                  Double(w) == nil, Self.numberWords[w] == nil else { continue }
            if !query.keywords.contains(norms[idx]) { query.keywords.append(norms[idx]) }
        }
        return query
    }

    private static func add(_ ingredient: QueryIngredient, to list: inout [QueryIngredient]) {
        if let idx = list.firstIndex(where: { $0.key == ingredient.key }) {
            list[idx].useUp = list[idx].useUp || ingredient.useUp
        } else {
            list.append(ingredient)
        }
    }

    private static func nextIsIngredient(_ slots: [Slot], after index: Int) -> Bool {
        var n = index + 1
        while n < slots.count {
            switch slots[n] {
            case .connector, .brk: n += 1
            case .item(.ingredient, _), .item(.tags, _): return true
            default: return false
            }
        }
        return false
    }

    // MARK: Numbers, durations, servings

    static let numberWords: [String: Double] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40,
        "fifty": 50, "sixty": 60, "ninety": 90,
    ]
    static let minuteUnits: Set<String> = ["min", "mins", "minute", "minutes", "m"]
    static let hourUnits: Set<String> = ["hour", "hours", "hr", "hrs", "h"]

    /// A number at `i`: digits, "forty five", "twelve", or "a"/"an" (one).
    static func number(_ words: [String], at i: Int) -> (Double, Int)? {
        guard i < words.count else { return nil }
        let w = words[i]
        if let d = Double(w) { return (d, 1) }
        if let n = numberWords[w] {
            if n >= 20, n.truncatingRemainder(dividingBy: 10) == 0, i + 1 < words.count, let ones = numberWords[words[i + 1]], ones < 10, ones > 0 {
                return (n + ones, 2)
            }
            return (n, 1)
        }
        if w == "a" || w == "an" { return (1, 1) }
        return nil
    }

    /// A duration at `i` in minutes: "30 min", "half an hour", "an hour and a half",
    /// "1 hour 15 minutes", "1.5 hours", "forty five minutes", "30-minute" (hyphen split).
    static func duration(_ words: [String], at i: Int) -> (Int, Int)? {
        func word(_ k: Int) -> String { k < words.count ? words[k] : "" }
        if word(i) == "half" {
            if hourUnits.contains(word(i + 1)) { return (30, 2) }
            if ["an", "a"].contains(word(i + 1)), hourUnits.contains(word(i + 2)) { return (30, 3) }
            return nil
        }
        guard let (n, length) = number(words, at: i) else { return nil }
        var k = i + length
        var value = n
        // "1 and a half hours"
        if word(k) == "and", word(k + 1) == "a", word(k + 2) == "half" { value += 0.5; k += 3 }
        let unit = word(k)
        if minuteUnits.contains(unit) {
            if unit == "m", Double(word(i)) == nil { return nil }
            return (Int(value.rounded()), k + 1 - i)
        }
        guard hourUnits.contains(unit) else { return nil }
        var minutes = value * 60
        k += 1
        if word(k) == "and", word(k + 1) == "a", word(k + 2) == "half" {
            minutes += 30; k += 3
        } else if let (extra, len) = (word(k) == "and" ? number(words, at: k + 1).map { ($0.0, $0.1 + 1) } : number(words, at: k)),
                  minuteUnits.contains(word(k + len)) {
            minutes += extra; k += len + 1
        }
        return (Int(minutes.rounded()), k - i)
    }

    static let servingsNouns: Set<String> = ["people", "persons", "person", "servings", "serving", "guests", "adults", "folks", "portions", "plates"]
    static let servingsVerbs: Set<String> = ["serves", "serve", "serving", "feeds", "feed", "feeding"]

    static func isServingsWord(_ words: [String], at i: Int) -> Bool {
        i < words.count && (servingsNouns.contains(words[i]) || (words[i] == "of" && i + 1 < words.count && words[i + 1] == "us"))
    }

    /// "for 4", "for four people", "serves 6", "feeds 2", "for the two of us", "a family of four", "6 people".
    static func servings(_ words: [String], at i: Int) -> (Int, Int)? {
        func word(_ k: Int) -> String { k < words.count ? words[k] : "" }
        func plausible(_ n: Double) -> Bool { n >= 1 && n <= 24 && n == n.rounded() }
        func nounLength(_ k: Int) -> Int { servingsNouns.contains(word(k)) ? 1 : (word(k) == "of" && word(k + 1) == "us" ? 2 : 0) }
        let w = word(i)
        if w == "for" || servingsVerbs.contains(w) {
            var k = i + 1
            if word(k) == "the" { k += 1 }
            guard word(k) != "a", word(k) != "an", let (n, len) = number(words, at: k), plausible(n) else { return nil }
            let after = k + len
            if minuteUnits.contains(word(after)) || hourUnits.contains(word(after)) || word(after) == "and" && word(after + 2) == "half" { return nil }
            // "for 2" alone is servings; "for the 2" needs "of us".
            if word(i + 1) == "the", nounLength(after) == 0 { return nil }
            return (Int(n), after + nounLength(after) - i)
        }
        if w == "family", word(i + 1) == "of", let (n, len) = number(words, at: i + 2), plausible(n) {
            return (Int(n), 2 + len)
        }
        if let (n, len) = number(words, at: i), w != "a", w != "an", plausible(n), servingsNouns.contains(word(i + len)) {
            return (Int(n), len + 1)
        }
        return nil
    }

    // MARK: Display

    static func tagSummary(_ tags: Set<IngredientTag>) -> [String] {
        guard !tags.isEmpty else { return [] }
        if tags.isSuperset(of: SwapEngine.forbiddenTags(for: .vegan)) { return ["vegan"] }
        if tags.isSuperset(of: SwapEngine.forbiddenTags(for: .vegetarian)) {
            return ["vegetarian"] + tags.subtracting(SwapEngine.forbiddenTags(for: .vegetarian)).map(\.rawValue).sorted().map { "no \($0)" }
        }
        if tags.isSuperset(of: [.meat, .pork, .beef, .poultry]) {
            return ["no meat"] + tags.subtracting([.meat, .pork, .beef, .poultry]).map(\.rawValue).sorted().map { "no \($0)" }
        }
        return tags.map(\.rawValue).sorted().map { "no \($0)" }
    }
}

/// Formatting shared by the finder's "why" lines and query chips.
public enum CookFinderFormat {
    /// "35 min", "1 hr", "1 hr 5 min".
    public static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) hr"
        default: return "\(h) hr \(m) min"
        }
    }
}
