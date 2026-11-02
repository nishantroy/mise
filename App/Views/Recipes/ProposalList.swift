import SwiftUI
import RecipeKit

/// A proposed recipe edit the user can untick before saving (adjust and "my version" screens).
struct EditProposal: Identifiable {
    let id = UUID()
    var edit: RecipeEdit
    var summary: String
    var included = true
    /// A change to one step (old → new): from the cook's feedback (ticked), or a model's
    /// rewording after an ingredient change (unticked).
    var rewrite: StepRewriteProposal? = nil
    /// Proposals this one relies on; if any is unticked, this one can't be applied.
    var dependsOn: [UUID] = []
    /// For a note tied to a step ("Step 7 (Chicken): …"): that step, which can be edited by hand instead.
    var noteStep: Int? = nil
}

extension Array where Element == EditProposal {
    /// Whether a proposal can be applied: everything it depends on is ticked.
    func isAvailable(_ proposal: EditProposal) -> Bool {
        proposal.dependsOn.allSatisfy { dep in first { $0.id == dep }?.included ?? false }
    }

    /// The ticked edits that can be applied, in order (step rewrites come last).
    var chosenEdits: [RecipeEdit] {
        filter { $0.included && isAvailable($0) }.map(\.edit)
    }

    /// Unticking a proposal also unticks the rewrites that rely on it.
    mutating func setIncluded(_ on: Bool, at index: Int) {
        guard indices.contains(index) else { return }
        self[index].included = on
        guard !on else { return }
        let id = self[index].id
        for i in indices where self[i].dependsOn.contains(id) { self[i].included = false }
    }

    /// Proposals for the assistant's edits from "I made this" feedback. Step rewrites and removals
    /// show a before/after and are ticked like the other edits; a note tied to a step remembers it.
    static func feedback(_ edits: [RecipeEdit], recipe: Recipe, changes: [StepChange]) -> [EditProposal] {
        edits.map { edit in
            EditProposal(edit: edit, summary: edit.summary(in: recipe), rewrite: changes.proposal(for: edit, in: recipe),
                         noteStep: changes.stepIndex(forNote: edit))
        }
    }

    /// Adds the model's rewrites. One that turns a step note into a step change takes the note's
    /// place (ticked, as the cook asked for it); the rest are appended unticked.
    mutating func add(_ rewrites: [StepRewriteProposal], base: [EditProposal]) {
        var others: [StepRewriteProposal] = []
        for rewrite in rewrites {
            if let k = rewrite.replacesEdit, base.indices.contains(k), let i = firstIndex(where: { $0.id == base[k].id }) {
                self[i] = EditProposal(edit: rewrite.edit, summary: "Change step \(rewrite.stepIndex + 1)",
                                       included: self[i].included, rewrite: rewrite)
            } else {
                others.append(rewrite)
            }
        }
        self += Self.rewrites(others, dependingOn: base)
    }

    /// The cook's own wording for the step a proposal is about; it becomes a ticked step change.
    mutating func setStepText(_ text: String, at index: Int, original: String) {
        guard indices.contains(index), let step = self[index].rewrite?.stepIndex ?? self[index].noteStep,
              !text.isEmpty, text != original else { return }
        var reason = self[index].rewrite?.reason
        if reason == nil, case let .addNote(note) = self[index].edit { reason = note }
        let rewrite = StepRewriteProposal(stepIndex: step, oldText: original, newText: text,
                                          dependsOn: self[index].rewrite?.dependsOn ?? [], reason: reason, fromFeedback: true)
        self[index].rewrite = rewrite
        self[index].edit = rewrite.edit
        self[index].summary = "Change step \(step + 1)"
        self[index].noteStep = nil
        self[index].included = true
    }

    /// Rewrite proposals mapped onto the edits they depend on (by position in `base`).
    static func rewrites(_ rewrites: [StepRewriteProposal], dependingOn base: [EditProposal]) -> [EditProposal] {
        rewrites.map { r in
            EditProposal(edit: r.edit, summary: "Reword step \(r.stepIndex + 1)", included: false, rewrite: r,
                         dependsOn: r.dependsOn.compactMap { base.indices.contains($0) ? base[$0].id : nil })
        }
    }
}

/// A step rewrite: the old text struck through and the new one, with a switch (off by default).
struct RewriteToggle: View {
    let rewrite: StepRewriteProposal
    @Binding var isOn: Bool
    var isAvailable = true
    let identifier: String

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text("Reword step \(rewrite.stepIndex + 1)").foregroundStyle(Color.mise.ink)
                Text(rewrite.oldText)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Color.mise.inkSecondary)
                    .strikethrough(true, color: Color.mise.inkSecondary)
                    .accessibilityLabel("Was: \(rewrite.oldText)")
                Text(rewrite.newText)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Color.mise.ink)
                    .accessibilityLabel("Becomes: \(rewrite.newText)")
                if !isAvailable {
                    Text("Needs the change it rewords.").font(Theme.Fonts.caption).foregroundStyle(Color.mise.inkSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .tint(Color.mise.accent)
        .disabled(!isAvailable)
        .accessibilityIdentifier(identifier)
    }
}

/// A pantry change implied by the user's version, offered next to the edits.
struct PantryProposal: Identifiable {
    var id: String { update.id }
    let update: PantryUpdate
    var included = true
}

/// One row of a proposal list: the summary and a switch.
struct ProposalToggle: View {
    let text: String
    @Binding var isOn: Bool
    let identifier: String

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(text).foregroundStyle(Color.mise.ink)
        }
        .tint(Color.mise.accent)
        .accessibilityIdentifier(identifier)
    }
}
