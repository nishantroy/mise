import Foundation

extension Array where Element == StepChange {
    /// The before/after for a step edit from feedback (a rewrite or a removal), or nil for any
    /// other edit. The UI ticks these by default, like the feedback's ingredient edits.
    public func proposal(for edit: RecipeEdit, in recipe: Recipe) -> StepRewriteProposal? {
        let reason = first { $0.edit == edit }?.clause
        switch edit {
        case let .updateStep(index, text) where recipe.steps.indices.contains(index):
            return StepRewriteProposal(stepIndex: index, oldText: recipe.steps[index], newText: text, dependsOn: [],
                                       reason: reason, fromFeedback: true)
        case let .removeStep(index) where recipe.steps.indices.contains(index):
            return StepRewriteProposal(stepIndex: index, oldText: recipe.steps[index], newText: "", dependsOn: [],
                                       reason: reason, fromFeedback: true)
        default:
            return nil
        }
    }

    /// The step a step-attached note ("Step 7 (Chicken): …") is about.
    public func stepIndex(forNote edit: RecipeEdit) -> Int? {
        guard case .addNote = edit else { return nil }
        return first { $0.edit == edit }?.stepIndex
    }
}

/// Word-level difference between two versions of a step: the shared start and end, and what
/// changed in between. Used to show a compact before/after.
public struct StepTextDiff: Hashable, Sendable {
    public var prefix: String
    public var removed: String
    public var added: String
    public var suffix: String

    public init(prefix: String, removed: String, added: String, suffix: String) {
        self.prefix = prefix
        self.removed = removed
        self.added = added
        self.suffix = suffix
    }

    public init(old: String, new: String) {
        let a = Self.tokens(old), b = Self.tokens(new)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var q = 0
        while q < a.count - p, q < b.count - p, a[a.count - 1 - q] == b[b.count - 1 - q] { q += 1 }
        self.init(prefix: a[..<p].joined(), removed: a[p..<(a.count - q)].joined(),
                  added: b[p..<(b.count - q)].joined(), suffix: a[(a.count - q)...].joined())
    }

    /// At most `context` words of unchanged text either side, with "…" where text was cut.
    public func compact(context: Int = 5) -> StepTextDiff {
        let pre = Self.tokens(prefix), suf = Self.tokens(suffix)
        return StepTextDiff(prefix: pre.count > context ? "…" + pre.suffix(context).joined() : prefix,
                            removed: removed, added: added,
                            suffix: suf.count > context ? suf.prefix(context).joined().trimmingCharacters(in: .whitespaces) + "…" : suffix)
    }

    /// Words with their trailing spaces, so `joined()` gives the text back.
    static func tokens(_ text: String) -> [String] {
        Rx.matches("^\\s+|\\S+\\s*", in: text).compactMap { $0[0] }
    }
}
