import Foundation

/// Sorts the prose in a pasted write-up (often from a chat assistant) that isn't an instruction:
/// tips and variations ("Go up to ½–1 tsp Sichuan peppercorn if you want a clear tingle",
/// "If it tastes flat…", "For more heat…", "Tip: …") become recipe notes; commentary aimed at
/// the reader ("The salt… are the fixes for the low flavor", "This works because…", "Enjoy!")
/// is dropped. Anything else in a prose line is kept as a note, so nothing the cook wrote is
/// lost silently except commentary.
public enum PasteProse {
    public enum Kind: Hashable, Sendable { case tip, commentary, other }

    /// Splits at sentence ends followed by a capital, quote or bracket ("… min. Stir …").
    public static func sentences(_ text: String) -> [String] {
        let marked = Rx.replace("([.!?])\\s+(?=[\\p{Lu}\"“(])", in: text, with: "$1\u{1}", [])
        return marked.split(separator: "\u{1}").map { String($0).trimmed }.filter { !$0.isEmpty }
    }

    public static func classify(_ sentence: String) -> Kind {
        if commentaryPatterns.contains(where: { Rx.test($0, sentence) }) { return .commentary }
        if tipPatterns.contains(where: { Rx.test($0, sentence) }) { return .tip }
        return .other
    }

    /// True when every sentence is a tip or commentary: nothing to do at the stove.
    static func isAllProse(_ line: String) -> Bool {
        let parts = sentences(line)
        return !parts.isEmpty && parts.allSatisfy { classify($0) != .other }
    }

    /// The line's notes (one per line: its tip and other sentences, joined) and its dropped
    /// commentary sentences.
    static func sort(_ line: String) -> (notes: [String], dropped: [String]) {
        var keep: [String] = [], dropped: [String] = []
        for sentence in sentences(stripNotePrefix(line)) {
            if classify(sentence) == .commentary { dropped.append(sentence) } else { keep.append(tidyTip(sentence)) }
        }
        return (keep.isEmpty ? [] : [keep.joined(separator: " ")], dropped)
    }

    /// "Go up to ½–1 tsp Sichuan peppercorn if you want a clear tingle." →
    /// "For a clear tingle, use ½–1 tsp Sichuan peppercorn." Other sentences are unchanged.
    public static func tidyTip(_ sentence: String) -> String {
        guard let m = Rx.firstMatch("^(?:go|use|add) up to (.+?),? if you (?:want|like|prefer|'d like|’d like) (.+?)[.!]?$", in: sentence),
              let amount = m[1], let goal = m[2] else { return sentence }
        return "For \(goal), use \(amount)."
    }

    static func hasNotePrefix(_ line: String) -> Bool {
        Rx.test(notePrefix, line)
    }

    static func stripNotePrefix(_ line: String) -> String {
        let stripped = Rx.replace(notePrefix, in: line, with: "").trimmed
        guard let first = stripped.first else { return line }
        return first.uppercased() + stripped.dropFirst()
    }

    static let notePrefix = "^(?:tips?|notes?|cook'?s notes?|variations?|hint|optional|make ahead)\\s*:\\s*"

    /// A heading that starts a section of notes rather than steps.
    static func isNotesHeading(_ heading: String) -> Bool {
        Rx.test("^(?:tips?|notes?|cook'?s notes?|recipe notes|variations?|make ahead|storage|to store|substitutions?)\\b", heading)
    }

    /// Starts with a cooking verb (or "Off the heat", "Once…"), so a closing line like "Serve hot"
    /// is still a step.
    static func startsLikeInstruction(_ line: String) -> Bool {
        guard let word = line.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "-" }).first else { return false }
        return instructionVerbs.contains(String(word))
    }

    static let instructionVerbs: Set<String> = [
        "add", "adjust", "arrange", "bake", "baste", "beat", "blanch", "blend", "blitz", "bloom", "boil", "braise",
        "break", "bring", "broil", "brown", "brush", "char", "check", "chill", "chop", "coat", "combine", "cook",
        "cool", "cover", "crack", "crush", "cut", "deglaze", "dice", "divide", "drain", "drizzle", "dry", "dust",
        "finish", "flip", "fold", "fry", "garnish", "grate", "grill", "grind", "heat", "in", "julienne", "keep",
        "knead", "ladle", "layer", "leave", "let", "marinate", "mash", "measure", "meanwhile", "melt", "microwave",
        "mince", "mix", "off", "once", "pat", "peel", "place", "plate", "pour", "preheat", "press", "pulse",
        "puree", "purée", "put", "reduce", "refrigerate", "remove", "rest", "return", "rinse", "roast", "roll",
        "rub", "saute", "sauté", "scatter", "scrape", "season", "sear", "serve", "set", "shred", "sift", "simmer",
        "slice", "smash", "soak", "soften", "spoon", "spread", "sprinkle", "squeeze", "steam", "stir", "stir-fry",
        "strain", "sweat", "taste", "then", "thicken", "toast", "top", "toss", "transfer", "trim", "turn",
        "warm", "wash", "when", "whisk", "wipe", "wrap", "zest",
    ]

    /// Conditional tips and variations.
    static let tipPatterns = [
        notePrefix,
        "^if\\b(?!\\s+using\\b)",
        "^for (?:more|extra|less|a|an|added|even|some|any)\\b",
        "\\b(?:go|use|add) up to\\b",
        "\\bif you (?:want|like|prefer|'d like|’d like|would like|have|can't|can’t|don't|don’t)\\b",
        "\\byou can (?:also )?\\w",
        "\\bfeel free\\b",
        "\\b(?:to make it|for a) (?:spicier|milder|richer|lighter|vegetarian|vegan)\\b",
    ]

    /// Explanation or chat aimed at the reader, not the recipe.
    static let commentaryPatterns = [
        "\\b(?:is|are) (?:the|what|your) (?:main |real |big )?(?:fix|fixes|key|keys|secret|trick|difference)\\b",
        "\\bfix(?:es)? for\\b",
        "^(?:this|that|these|those) (?:works?|is|are|was|were|should|will|would|version|recipe|gives?|keeps?|makes?|changes?|tweaks?|adjustments?|helps?)\\b",
        "^(?:that's|that’s|it's|it’s) (?:what|why|the)\\b",
        "\\bthe (?:key|secret|trick) (?:is|here)\\b",
        "\\bwhy (?:this|it) works\\b",
        "^(?:enjoy|happy cooking|hope|good luck|bon app|let me know|here(?:'s| is| are)|here’s|sure|great question|okay|ok)\\b",
        "\\b(?:let me know|hope (?:this|that|it|you))\\b",
        "\\b(?:compared (?:to|with)|than (?:before|last time)|last time)\\b",
    ]
}
