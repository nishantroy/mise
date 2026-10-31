import Foundation

/// Ranks saved recipes by how well their titles match pasted text (its first line), so a
/// shared "my version" can be attached to the right recipe with the best guess first.
public enum TitleMatcher {
    static let ignored: Set<String> = [
        "the", "a", "an", "and", "with", "of", "my", "your", "recipe", "version", "easy", "best", "quick",
        "serves", "serving", "for", "in", "on", "to",
    ]

    /// The title a pasted recipe would get: its first non-empty line, minus "(serves 4)".
    public static func title(ofPasted text: String) -> String {
        guard let first = HTMLText.lines(fromText: text).first?.text else { return "" }
        return StepStyleParser.titleAndServings(first).title
    }

    /// 0…1: shared words over all words (Jaccard), ignoring filler words and numbers.
    public static func score(_ a: String, _ b: String) -> Double {
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        return Double(wa.intersection(wb).count) / Double(wa.union(wb).count)
    }

    /// `items` sorted by title score against `text`, best first; ties keep their order.
    public static func ranked<T>(_ items: [T], title: (T) -> String, against text: String) -> [T] {
        let target = Self.title(ofPasted: text)
        return items.enumerated()
            .map { (offset: $0.offset, item: $0.element, score: score(target, title($0.element))) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.item)
    }

    static func words(_ text: String) -> Set<String> {
        Set(IngredientCatalog.normalise(text).split(separator: " ").map(String.init)
            .filter { !ignored.contains($0) && Int($0) == nil })
    }
}
