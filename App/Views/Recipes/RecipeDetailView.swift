import SwiftUI
import SwiftData
import RecipeKit

struct RecipeDetailView: View {
    @Bindable var saved: SavedRecipe

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AssistantProvider.self) private var provider
    @Query private var profiles: [UserProfile]
    @State private var servings: Int?
    @State private var showingCheck = false
    @State private var showingAdjust = false
    @State private var confirmReset = false
    @State private var confirmDelete = false
    @State private var rechecking = false

    private var recipe: Recipe { saved.recipe }
    private var displayed: Recipe {
        guard let servings else { return recipe }
        return recipe.scaled(to: servings)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if recipe.imageURL != nil {
                    RecipeImage(url: recipe.imageURL)
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
                titleBlock
                if recipe.servings != nil { servingsCard }
                ingredientsCard
                stepsCard
                if !recipe.notes.isEmpty { notesCard }
                historyCard
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.m)
        }
        .miseScreenBackground()
        .safeAreaInset(edge: .bottom) {
            Button("I made this") { showingAdjust = true }
                .buttonStyle(.misePrimary)
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.vertical, Theme.Spacing.s)
                .background(Color.mise.background)
                .accessibilityIdentifier("detail.madeThis")
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Check ingredients", systemImage: "checklist") { showingCheck = true }
                    Button("Re-check time and cuisine", systemImage: "clock.arrow.circlepath") { recheck() }
                        .disabled(rechecking)
                    if let url = recipe.sourceURL {
                        Link(destination: url) { Label("Open original page", systemImage: "safari") }
                    }
                    Button("Reset to original", systemImage: "arrow.uturn.backward") { confirmReset = true }
                    Button("Delete recipe", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("detail.menu")
            }
        }
        .confirmationDialog("Reset to the imported version?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset to original", role: .destructive) {
                saved.resetToOriginal()
                servings = nil
                try? context.save()
            }
        } message: {
            Text("Your changes stay in the history.")
        }
        .confirmationDialog("Delete this recipe?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                context.delete(saved)
                try? context.save()
                dismiss()
            }
        }
        .sheet(isPresented: $showingCheck) {
            NavigationStack {
                IngredientCheckView(recipe: recipe, existing: saved) { _ in showingCheck = false }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingCheck = false } }
                    }
            }
        }
        .sheet(isPresented: $showingAdjust) {
            NavigationStack {
                AdjustRecipeView(saved: saved)
            }
        }
    }

    // MARK: Sections

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(recipe.title).serifTitle(Theme.Fonts.header).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("detail.title")
            HStack(spacing: Theme.Spacing.s) {
                if let time = RecipeFormat.time(recipe) {
                    Text(time).accessibilityLabel(recipe.displayTime?.isEstimate == true ? "About \(time.dropFirst()), estimated" : time)
                        .accessibilityIdentifier("detail.time")
                }
                CuisineMenu(cuisine: RecipeFormat.cuisine(recipe), onPick: setCuisine, onClear: { setCuisine(nil) })
                if saved.timesCooked > 0 { Text("Cooked \(saved.timesCooked)×") }
                if let rating = saved.rating, rating != 0 {
                    Image(systemName: rating > 0 ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                        .accessibilityLabel(rating > 0 ? "Liked" : "Disliked")
                }
            }
            .font(Theme.Fonts.meta)
            .foregroundStyle(Color.mise.inkSecondary)
            TimeInsightView(recipe: recipe, prefs: profiles.first?.prefs, isRechecking: rechecking)
            if let host = recipe.sourceURL?.host() {
                Text(host.replacingOccurrences(of: "www.", with: ""))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color.mise.inkSecondary)
            }
        }
    }

    // MARK: Actions

    private func setCuisine(_ cuisine: String?) {
        saved.setCuisine(cuisine)
        try? context.save()
    }

    /// Re-runs the cuisine guess and time estimate (fills in recipes saved before they existed).
    private func recheck() {
        rechecking = true
        let current = saved.recipe
        let assistant = provider.assistant
        Task {
            let enriched = await RecipeInsights.enrich(current, using: assistant)
            saved.updateInsights(cuisineGuess: enriched.cuisineIsGuess ? enriched.cuisine : nil,
                                 estimate: enriched.timeEstimate)
            try? context.save()
            rechecking = false
        }
    }

    private var servingsCard: some View {
        MiseCard {
            let current = servings ?? recipe.servings ?? 1
            Stepper(value: Binding(get: { current }, set: { servings = $0 == recipe.servings ? nil : $0 }), in: 1...50) {
                HStack {
                    Text("Servings").foregroundStyle(Color.mise.ink)
                    Spacer()
                    Text("\(current)").monospacedDigit().foregroundStyle(Color.mise.ink)
                        .accessibilityIdentifier("detail.servingsValue")
                }
            }
            .accessibilityIdentifier("detail.servings")
        }
    }

    private var ingredientsCard: some View {
        SectionCard(title: "Ingredients") {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach(displayed.ingredients) { ing in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        Text(RecipeFormat.amount(ing) ?? "")
                            .monospacedDigit()
                            .foregroundStyle(Color.mise.ink)
                            .frame(minWidth: 72, alignment: .leading)
                            .fontWeight(.semibold)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(RecipeFormat.capitalised(ing.name)).foregroundStyle(Color.mise.ink)
                            if let note = ing.note {
                                Text(note).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("detail.ingredient")
                }
            }
        }
    }

    private var stepsCard: some View {
        SectionCard(title: "Steps") {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        Text("\(index + 1)")
                            .font(Theme.Fonts.badge)
                            .foregroundStyle(Color.mise.onAccent)
                            .frame(minWidth: Theme.Size.stepBadge, minHeight: Theme.Size.stepBadge)
                            .background(Color.mise.accent, in: Circle())
                            .accessibilityLabel("Step \(index + 1)")
                        Text(step).foregroundStyle(Color.mise.ink).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("detail.step")
                }
            }
        }
    }

    private var notesCard: some View {
        SectionCard(title: "Notes") {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(Array(recipe.notes.enumerated()), id: \.offset) { _, note in
                    Label(note, systemImage: "text.quote")
                        .foregroundStyle(Color.mise.ink)
                        .accessibilityIdentifier("detail.note")
                }
            }
        }
    }

    private var historyCard: some View {
        SectionCard(title: "History") {
            let revisions = saved.revisions
            if revisions.isEmpty {
                Text("No changes yet.").foregroundStyle(Color.mise.inkSecondary)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    ForEach(revisions.reversed()) { revision in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(revision.date, format: .dateTime.day().month().year().hour().minute())
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Color.mise.inkSecondary)
                            Text(revision.summary).foregroundStyle(Color.mise.ink)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("detail.revision")
                    }
                }
            }
        }
    }
}

#Preview("Light") {
    let container = PreviewData.container
    let saved = try! container.mainContext.fetch(FetchDescriptor<SavedRecipe>()).first!
    return NavigationStack { RecipeDetailView(saved: saved) }
        .modelContainer(container)
        .environment(AssistantProvider())
}

#Preview("Dark") {
    let container = PreviewData.container
    let saved = try! container.mainContext.fetch(FetchDescriptor<SavedRecipe>()).first!
    return NavigationStack { RecipeDetailView(saved: saved) }
        .modelContainer(container)
        .environment(AssistantProvider())
        .preferredColorScheme(.dark)
}
