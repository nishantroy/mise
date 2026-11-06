import SwiftUI
import RecipeKit

/// "Find a substitute" on the recipe page: an option picked for one ingredient, waiting for
/// "Just this time" or "Update the recipe".
struct SubstituteChoice: Identifiable {
    let id = UUID()
    /// As shown on the page (scaled to the servings there).
    let ingredient: Ingredient
    /// nil: leave it out.
    let suggestion: SwapSuggestion?
    let consequence: String?

    var isLeaveOut: Bool { suggestion == nil || suggestion?.isLeaveOut == true }

    /// "Use ginger and garlic instead of ginger garlic paste?", "Leave out curry leaves?".
    var question: String {
        guard let suggestion, !isLeaveOut else { return "Leave out \(ingredient.name)?" }
        return "Use \(suggestion.items.map(\.name).joined(separator: " and ")) instead of \(ingredient.name)?"
    }
}

/// What Undo needs after "Update the recipe".
struct AppliedRecipeSwap {
    let revisionID: UUID?
    let before: Recipe
    let session: CookSession?
    let pantryKey: String
    let pantryBefore: String?
    let name: String
}

enum SubstituteDecision {
    /// A cook session with the swap in, for the next cook (or the one in progress).
    case justThisTime
    /// Saved in the recipe as a revision.
    case updateRecipe
}

/// The tap / "Find a substitute" sheet: cook mode's swap options for one ingredient, then the
/// one question.
struct FindSubstituteSheet: View {
    let ingredient: Ingredient
    /// The recipe as shown (scaled).
    let recipe: Recipe
    let cookInProgress: Bool
    var onDecide: (SubstituteChoice, SubstituteDecision) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var choice: SubstituteChoice?

    var body: some View {
        NavigationStack {
            SwapChoicesView(ingredient: ingredient, recipe: recipe, purpose: .recipe) { suggestion, consequence in
                choice = SubstituteChoice(ingredient: ingredient, suggestion: suggestion, consequence: consequence)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("substitute.cancel")
                }
            }
            .substituteDecision($choice, cookInProgress: cookInProgress, onDecide: onDecide)
        }
    }
}

extension View {
    /// Asks "Just this time" or "Update the recipe" for a picked substitute.
    func substituteDecision(_ choice: Binding<SubstituteChoice?>, cookInProgress: Bool,
                            onDecide: @escaping (SubstituteChoice, SubstituteDecision) -> Void) -> some View {
        confirmationDialog(choice.wrappedValue?.question ?? "", isPresented: Binding(
            get: { choice.wrappedValue != nil }, set: { if !$0 { choice.wrappedValue = nil } }
        ), titleVisibility: .visible, presenting: choice.wrappedValue) { picked in
            Button("Just this time") { onDecide(picked, .justThisTime) }
                .accessibilityIdentifier("substitute.justThisTime")
            Button("Update the recipe") { onDecide(picked, .updateRecipe) }
                .accessibilityIdentifier("substitute.updateRecipe")
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(cookInProgress
                 ? "Just this time adds it to the cook in progress. Updating the recipe saves it as a change and ends that cook."
                 : "Just this time gets it ready for your next cook. Updating the recipe saves it as a change you can undo.")
        }
    }
}

/// "Swap ready for your next cook": swaps chosen "just this time", before cook mode was opened.
struct PlannedSwapsCard: View {
    let swaps: [CookSwap]
    var onRemove: (CookSwap) -> Void

    var body: some View {
        ReviewCard(tone: .herb, systemImage: "arrow.triangle.swap",
                   title: swaps.count == 1 ? "Swap ready for your next cook" : "Swaps ready for your next cook") {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach(swaps) { swap in
                    HStack(spacing: Theme.Spacing.s) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(swap.label).foregroundStyle(Color.mise.ink)
                            if let line = swap.consequence {
                                Text(line).font(Theme.Fonts.caption).foregroundStyle(Color.mise.inkSecondary)
                            }
                        }
                        Spacer(minLength: Theme.Spacing.xs)
                        Button("Remove") { onRemove(swap) }
                            .buttonStyle(.miseSecondary)
                            .fixedSize()
                            .accessibilityLabel("Remove: \(swap.label)")
                            .accessibilityIdentifier("detail.plannedSwap.remove")
                    }
                }
                Text("Start cooking and it's already in. The recipe itself doesn't change.")
                    .font(Theme.Fonts.caption).foregroundStyle(Color.mise.inkSecondary)
            }
        }
        .accessibilityIdentifier("detail.plannedSwaps")
    }
}

/// A short confirmation above the bottom bar, with an optional Undo.
struct SwapToast: View {
    let message: String
    var onUndo: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.mise.herb).accessibilityHidden(true)
            Text(message).foregroundStyle(Color.mise.ink).font(Theme.Fonts.meta)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Spacing.xs)
            if let onUndo {
                Button("Undo", action: onUndo)
                    .buttonStyle(.miseSecondary)
                    .fixedSize()
                    .accessibilityIdentifier("detail.swapUndo")
            }
        }
        .padding(Theme.Spacing.s)
        .background(Color.mise.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Color.mise.divider, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.swapToast")
    }
}
