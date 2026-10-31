import SwiftUI
import SwiftData
import RecipeKit

/// First-launch questions: diet and avoid list, dislikes and spice, cuisines and household, pantry picks.
struct OnboardingFlow: View {
    @Environment(\.modelContext) private var context
    @State private var step = 0
    @State private var prefs = UserPreferences()
    @State private var pantryPicks: Set<String> = []

    private static let pageCount = 4
    private let questions = ["What do you eat?", "Anything you'd rather skip?", "How do you cook?", "What's in your pantry?"]
    private let subtitles = [
        "Mise flags ingredients that don't fit, and suggests swaps.",
        "Add ingredients you dislike and pick how much heat you like.",
        "This helps Mise suggest sensible amounts and times.",
        "Tick what you usually have. Mise won't ask about these.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(questions[step])
                            .serifTitle(Theme.Fonts.header)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("onboarding.title")
                        Text(subtitles[step])
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Color.mise.inkSecondary)
                    }
                    page
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.top, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.l)
                .id(step)
            }
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: Theme.Spacing.m) {
                PageDots(count: Self.pageCount, current: step)
                HStack(spacing: Theme.Spacing.s) {
                    if step > 0 {
                        Button("Back") { withAnimation { step -= 1 } }
                            .buttonStyle(.miseSecondary)
                            .accessibilityIdentifier("onboarding.back")
                    }
                    if step < Self.pageCount - 1 {
                        Button("Continue") { withAnimation { step += 1 } }
                            .buttonStyle(.misePrimary)
                            .accessibilityIdentifier("onboarding.next")
                    } else {
                        Button("Get started", action: finish)
                            .buttonStyle(.misePrimary)
                            .accessibilityIdentifier("onboarding.finish")
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.m)
        }
        .background(Color.mise.background.ignoresSafeArea())
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 0:
            QuestionBlock(title: "Diet") { DietEditor(prefs: $prefs) }
            QuestionBlock(title: "Avoid", footnote: "Recipes with these get flagged, with swaps.") { AvoidEditor(prefs: $prefs) }
        case 1:
            QuestionBlock(title: "Ingredients you dislike") { DislikesEditor(prefs: $prefs) }
            QuestionBlock(title: "How much heat?") { SpiceEditor(prefs: $prefs) }
        case 2:
            QuestionBlock(title: "Cuisines you cook") { CuisineEditor(prefs: $prefs) }
            QuestionBlock(title: "Weeknight cooking time") { WeeknightEditor(prefs: $prefs) }
            QuestionBlock(title: "Who are you cooking for?") { HouseholdEditor(prefs: $prefs) }
        default:
            PantryPickGrid(picks: $pantryPicks)
            Text("You can change this any time in the Pantry tab.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color.mise.inkSecondary)
        }
    }

    private func finish() {
        let catalog = IngredientCatalog.shared
        for id in pantryPicks {
            context.setPantry(key: id, displayName: catalog.displayName(for: id), status: .have)
        }
        let profile = context.profile()
        profile.prefs = prefs
        profile.onboardingDone = true
        try? context.save()
    }
}

/// Three-column grid of pantry chips.
struct PantryPickGrid: View {
    @Binding var picks: Set<String>
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.xs),
                            count: typeSize.isAccessibilitySize ? 1 : 3)
        LazyVGrid(columns: columns, spacing: Theme.Spacing.xs) {
            ForEach(IngredientCatalog.quickPickIDs, id: \.self) { id in
                let name = IngredientCatalog.shared.displayName(for: id)
                Chip(title: name.prefix(1).uppercased() + name.dropFirst(), isOn: Binding(
                    get: { picks.contains(id) },
                    set: { on in if on { picks.insert(id) } else { picks.remove(id) } }
                ))
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("pantry.pick.\(id)")
            }
        }
    }
}

#Preview("Light") {
    OnboardingFlow().modelContainer(Persistence.inMemory())
}

#Preview("Dark") {
    OnboardingFlow().modelContainer(Persistence.inMemory()).preferredColorScheme(.dark)
}

#Preview("Largest text") {
    OnboardingFlow().modelContainer(Persistence.inMemory()).dynamicTypeSize(.accessibility5)
}
