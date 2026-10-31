import Foundation

/// The rules' view of a recipe's cuisine: a scored vote over ingredient and title signals.
public struct CuisineGuess: Hashable, Sendable {
    /// The winner, or nil when there's no clear one.
    public var cuisine: String?
    /// Score of the top cuisine (even when it isn't a clear winner).
    public var score: Int
    /// Score of the runner-up.
    public var runnerUpScore: Int
    /// Every cuisine with a non-zero score.
    public var scores: [String: Int]
    /// What voted for the winner, e.g. "oyster sauce", "title: kung pao". Empty when nil.
    public var signals: [String]

    /// Confident enough that asking the model wouldn't add anything.
    public var isStrong: Bool {
        cuisine != nil && score >= CuisineGuesser.strongScore && score >= 2 * runnerUpScore
    }
}

/// Guesses a cuisine from the catalog's `cuisines` signals and title keywords.
///
/// Scoring: each matched catalog entry votes once (per recipe) with its `cuisineVote` for every
/// cuisine it lists (3 for a strongly indicative single-cuisine entry like oyster sauce, 1 for
/// shared or generic ones like soy sauce). Title keywords vote too: a cuisine name ("Thai") 6, a
/// dish name ("kung pao", "carbonara") 4, a looser hint ("curry", "fried rice") 2.
/// A winner needs at least `minimumScore` and a lead of `minimumMargin`, so soy sauce alone (1)
/// or soy sauce + sesame oil + rice vinegar (a three-way tie) gives nil.
public struct CuisineGuesser: Sendable {
    /// Same list as onboarding, so a guess always matches a cuisine the user can pick.
    public static let vocabulary = UserPreferences.cuisineChoices
    public static let minimumScore = 3
    public static let minimumMargin = 2
    public static let strongScore = 6

    public let catalog: IngredientCatalog

    public init(catalog: IngredientCatalog = .shared) {
        self.catalog = catalog
    }

    public func guess(_ recipe: Recipe) -> String? { analyse(recipe).cuisine }

    public func analyse(_ recipe: Recipe) -> CuisineGuess {
        var scores: [String: Int] = [:]
        var signals: [String: [String]] = [:]

        var seen: Set<String> = []
        for ingredient in recipe.ingredients {
            guard let entry = ingredient.catalogID.flatMap(catalog.entry(id:)) ?? catalog.match(ingredient.name),
                  !seen.contains(entry.id) else { continue }
            seen.insert(entry.id)
            let vote = entry.cuisineVote
            guard vote > 0 else { continue }
            for cuisine in entry.cuisines ?? [] where Self.vocabulary.contains(cuisine) {
                scores[cuisine, default: 0] += vote
                signals[cuisine, default: []].append(entry.displayName)
            }
        }

        let title = " \(IngredientCatalog.normalise(recipe.title)) "
        var titleHits: [String: Int] = [:]
        for keyword in Self.titleKeywords where title.contains(" \(keyword.normalised) ") {
            // One title vote per cuisine (the strongest), so "tikka masala" isn't counted twice.
            if keyword.weight > titleHits[keyword.cuisine, default: 0] {
                titleHits[keyword.cuisine] = keyword.weight
                signals[keyword.cuisine, default: []].removeAll { $0.hasPrefix("title: ") }
                signals[keyword.cuisine, default: []].append("title: \(keyword.phrase)")
            }
        }
        for (cuisine, weight) in titleHits { scores[cuisine, default: 0] += weight }

        let ranked = scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let top = ranked.first
        let runnerUp = ranked.dropFirst().first?.value ?? 0
        let topScore = top?.value ?? 0
        let winner = topScore >= Self.minimumScore && topScore - runnerUp >= Self.minimumMargin ? top?.key : nil
        return CuisineGuess(cuisine: winner, score: topScore, runnerUpScore: runnerUp, scores: scores,
                            signals: winner.map { signals[$0] ?? [] } ?? [])
    }

    /// Maps a model's choice ("Middle Eastern", "other", "chinese") onto the vocabulary.
    /// "Other" and anything unrecognised become nil.
    public static func mapModelChoice(_ raw: String) -> String? {
        let key = raw.lowercased().filter(\.isLetter)
        guard !key.isEmpty else { return nil }
        return vocabulary.first { $0.lowercased().filter(\.isLetter) == key }
    }

    // MARK: Title keywords

    struct Keyword: Sendable {
        var phrase: String
        var cuisine: String
        var weight: Int
        var normalised: String
    }

    static let titleKeywords: [Keyword] = {
        let groups: [(cuisine: String, name: [String], dish: [String], hint: [String])] = [
            ("Chinese",
             ["chinese", "sichuan", "szechuan", "cantonese", "hunan", "shanghai", "beijing", "peking"],
             ["kung pao", "gong bao", "chow mein", "lo mein", "chow fun", "mapo", "char siu", "dan dan", "wonton",
              "dim sum", "general tso", "egg foo young", "xiaolongbao", "congee", "twice cooked", "red braised",
              "hot and sour", "bao", "jiaozi", "zhajiangmian", "lion s head"],
             ["fried rice", "sweet and sour", "dumpling", "stir fry", "stir fried"]),
            ("Indian",
             ["indian", "punjabi", "goan", "kerala", "bengali", "gujarati", "hyderabadi", "chettinad"],
             ["tikka", "masala", "biryani", "dal", "daal", "dhal", "korma", "vindaloo", "paneer", "tandoori", "saag",
              "palak", "chana", "chole", "aloo", "gobi", "naan", "roti", "paratha", "samosa", "pakora", "bhaji",
              "raita", "rogan josh", "butter chicken", "jalfrezi", "dosa", "idli", "sambar", "rasam", "khichdi",
              "kheer", "pulao", "keema", "makhani", "bhuna", "chaat", "rajma"],
             ["curry"]),
            ("Japanese",
             ["japanese"],
             ["ramen", "teriyaki", "katsu", "tonkatsu", "sushi", "miso", "udon", "soba", "tempura", "yakitori",
              "okonomiyaki", "onigiri", "donburi", "karaage", "oyakodon", "katsudon", "sukiyaki", "shabu shabu",
              "chawanmushi", "takoyaki", "nikujaga", "tamagoyaki", "yakisoba", "gyudon", "matcha"],
             ["gyoza", "edamame"]),
            ("Korean",
             ["korean"],
             ["bulgogi", "bibimbap", "kimchi", "japchae", "tteokbokki", "galbi", "kalbi", "gochujang", "jjigae",
              "kimbap", "gimbap", "sundubu", "dakgalbi", "bossam", "pajeon"],
             []),
            ("Thai",
             ["thai"],
             ["pad thai", "tom yum", "tom kha", "larb", "laab", "massaman", "panang", "pad see ew", "pad kra pao",
              "khao soi", "som tam", "green curry", "red curry", "yellow curry", "khao pad", "pad krapow"],
             ["satay"]),
            ("Italian",
             ["italian", "tuscan", "sicilian", "neapolitan", "venetian", "milanese"],
             ["carbonara", "risotto", "lasagna", "lasagne", "gnocchi", "bolognese", "pesto", "focaccia", "tiramisu",
              "cacio e pepe", "amatriciana", "puttanesca", "arrabbiata", "parmigiana", "osso buco", "minestrone",
              "ragu", "bruschetta", "caprese", "panna cotta", "arancini", "saltimbocca", "piccata", "alfredo",
              "ravioli", "tortellini", "cannoli", "ciabatta", "pizza", "polenta", "frittata", "marsala", "aglio e olio"],
             ["pasta", "spaghetti", "penne", "linguine", "fettuccine", "rigatoni"]),
            ("Mexican",
             ["mexican", "oaxacan", "yucatan"],
             ["taco", "burrito", "enchilada", "quesadilla", "guacamole", "salsa verde", "carnitas", "pozole",
              "tamale", "mole", "fajita", "elote", "chilaquile", "tostada", "birria", "barbacoa", "al pastor",
              "horchata", "huevos rancheros", "pico de gallo", "chile relleno", "chiles relleno", "tinga", "sope"],
             ["salsa", "ceviche", "churro", "nacho"]),
            ("Middle Eastern",
             ["middle eastern", "lebanese", "turkish", "persian", "israeli", "syrian", "palestinian", "levantine",
              "moroccan", "iranian", "egyptian"],
             ["hummus", "houmous", "falafel", "shakshuka", "shakshouka", "shawarma", "tabbouleh", "fattoush", "kofta",
              "kofte", "baba ganoush", "baba ghanoush", "labneh", "manakish", "mujadara", "muhammara", "kibbeh",
              "freekeh", "tagine", "baklava", "za atar", "zaatar", "dukkah", "koshari"],
             ["kebab", "halloumi", "pita", "pitta"]),
            ("French",
             ["french", "provencal", "parisian", "normandy", "lyonnaise"],
             ["ratatouille", "coq au vin", "bourguignon", "dauphinoise", "quiche", "crepe", "souffle", "cassoulet",
              "bouillabaisse", "croque monsieur", "croque madame", "nicoise", "tarte tatin", "beurre blanc",
              "bearnaise", "hollandaise", "confit", "madeleine", "eclair", "profiterole", "vichyssoise",
              "pot au feu", "blanquette", "clafoutis", "gratin", "galette", "brioche", "croissant"],
             []),
            ("American",
             ["american", "cajun", "creole", "tex mex"],
             ["mac and cheese", "macaroni and cheese", "meatloaf", "sloppy joe", "cornbread", "buffalo wing",
              "cobbler", "pot roast", "jambalaya", "gumbo", "clam chowder", "biscuit and gravy", "pulled pork",
              "pecan pie", "key lime pie", "pumpkin pie", "hot dog", "grit", "hush puppy", "cheesesteak",
              "brownie", "chocolate chip cookie", "smore", "s more"],
             ["burger", "coleslaw", "barbecue", "bbq"]),
        ]
        var out: [Keyword] = []
        for g in groups {
            for p in g.name { out.append(Keyword(phrase: p, cuisine: g.cuisine, weight: 6, normalised: IngredientCatalog.normalise(p))) }
            for p in g.dish { out.append(Keyword(phrase: p, cuisine: g.cuisine, weight: 4, normalised: IngredientCatalog.normalise(p))) }
            for p in g.hint { out.append(Keyword(phrase: p, cuisine: g.cuisine, weight: 2, normalised: IngredientCatalog.normalise(p))) }
        }
        return out
    }()
}
