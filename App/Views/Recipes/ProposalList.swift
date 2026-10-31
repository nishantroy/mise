import SwiftUI
import RecipeKit

/// A proposed recipe edit the user can untick before saving (adjust and "my version" screens).
struct EditProposal: Identifiable {
    let id = UUID()
    let edit: RecipeEdit
    let summary: String
    var included = true
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
