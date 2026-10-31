import SwiftUI
import RecipeKit

/// A proposed recipe edit the user can untick before saving (adjust and "my version" screens).
struct EditProposal: Identifiable {
    let id = UUID()
    let edit: RecipeEdit
    let summary: String
    var included = true
    /// A model's rewrite of one step (old → new), offered unticked.
    var rewrite: StepRewriteProposal? = nil
    /// Proposals this one relies on; if any is unticked, this one can't be applied.
    var dependsOn: [UUID] = []
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
