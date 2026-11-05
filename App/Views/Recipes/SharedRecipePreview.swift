import SwiftUI
import SwiftData
import UIKit
import RecipeKit

/// A `.mise` file a friend sent: their recipe (and photo) before it's saved. "Save recipe" goes
/// on to the usual ingredient check, which saves it with the friend's version as the original.
struct SharedRecipePreview: View {
    let data: Data
    /// Called with the saved recipe, or nil when cancelled.
    var onFinished: (SavedRecipe?) -> Void

    @Query(sort: \SavedRecipe.updatedAt, order: .reverse) private var recipes: [SavedRecipe]
    @State private var file: SharedRecipeFile?
    @State private var failure: SharedRecipeFile.Failure?
    /// The friend's photo, re-encoded like a cooking photo (downscaled, metadata stripped).
    @State private var photo: ProcessedCookPhoto?
    @State private var photoImage: UIImage?
    @State private var loading = true
    @State private var checking = false

    var body: some View {
        Group {
            if let file {
                content(file)
            } else if let failure {
                EmptyState(systemImage: "doc.questionmark", title: "Can't open this recipe", message: failure.message,
                           buttonTitle: "Close") { onFinished(nil) }
                    .accessibilityIdentifier("sharedRecipe.error")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .miseScreenBackground()
        .navigationTitle("Shared recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onFinished(nil) }.accessibilityIdentifier("sharedRecipe.cancel")
            }
        }
        .navigationDestination(isPresented: $checking) {
            if let file {
                IngredientCheckView(recipe: file.recipe, existing: nil, shared: .init(photo: photo)) { saved in
                    onFinished(saved)
                }
            }
        }
        .task { await load() }
    }

    private func content(_ file: SharedRecipeFile) -> some View {
        let recipe = file.recipe
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if let photoImage {
                    Color.mise.surfaceSunken
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .overlay { Image(uiImage: photoImage).resizable().scaledToFill() }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .accessibilityLabel("Photo of the dish")
                } else if recipe.imageURL != nil {
                    RecipeImage(url: recipe.imageURL)
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Badge(title: "Shared recipe", systemImage: "person.2", tone: Color.mise.accent)
                    Text(recipe.title).serifTitle(Theme.Fonts.header).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("sharedRecipe.title")
                    let meta = [recipe.servings.map { "Serves \($0)" }, RecipeFormat.time(recipe), RecipeFormat.cuisine(recipe)]
                        .compactMap { $0 }
                    if !meta.isEmpty {
                        Text(meta.joined(separator: " · ")).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                    }
                    if let host = recipe.sourceURL?.host() {
                        Text("Originally from \(host.replacingOccurrences(of: "www.", with: ""))")
                            .font(Theme.Fonts.caption).foregroundStyle(Color.mise.inkSecondary)
                    }
                }
                if let existing = duplicate(of: file) {
                    ReviewCard(tone: .caution, systemImage: "doc.on.doc", title: "You already have \u{201C}\(existing.title)\u{201D}",
                               subtitle: "Saving adds this as a separate recipe. Yours stays as it is; delete the one you don't want.") {
                        EmptyView()
                    }
                    .accessibilityIdentifier("sharedRecipe.duplicate")
                }
                if !recipe.ingredients.isEmpty {
                    SectionCard(title: "Ingredients") {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            ForEach(recipe.ingredients) { ingredient in
                                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                                    Text(RecipeFormat.amount(ingredient) ?? "")
                                        .monospacedDigit().fontWeight(.semibold)
                                        .frame(minWidth: 72, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(RecipeFormat.capitalised(ingredient.name))
                                        if let note = ingredient.note {
                                            Text(note).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                                        }
                                    }
                                }
                                .foregroundStyle(Color.mise.ink)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                if !recipe.steps.isEmpty {
                    SectionCard(title: "Steps") {
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
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
                            }
                        }
                    }
                }
                if !recipe.notes.isEmpty {
                    SectionCard(title: "Notes") {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            ForEach(Array(recipe.notes.enumerated()), id: \.offset) { _, note in
                                Label(note, systemImage: "text.quote").foregroundStyle(Color.mise.ink)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.m)
        }
        .safeAreaInset(edge: .bottom) {
            Button { checking = true } label: {
                if loading { ProgressView().tint(Color.mise.onAccent) } else { Text("Save recipe") }
            }
            .buttonStyle(.misePrimary)
            .disabled(loading)
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.s)
            .background(Color.mise.background)
            .accessibilityIdentifier("sharedRecipe.save")
        }
    }

    /// A saved recipe from the same link, or with the same title. Kept simple: saving always
    /// adds a new recipe, and this only warns.
    private func duplicate(of file: SharedRecipeFile) -> SavedRecipe? {
        let title = file.recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source = file.recipe.sourceURL
        return recipes.first { saved in
            if saved.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title { return true }
            guard let source else { return false }
            return saved.recipe.sourceURL == source || saved.original.sourceURL == source
        }
    }

    private func load() async {
        guard file == nil, failure == nil else { return }
        do {
            let read = try SharedRecipeFile.read(data)
            file = read
            if let shared = read.photo?.data {
                let processed = await Task.detached(priority: .userInitiated) { CookPhotoProcessor.process(shared) }.value
                photo = processed
                photoImage = processed.flatMap { UIImage(data: $0.photo) }
            }
        } catch {
            failure = error
        }
        loading = false
    }
}

#Preview("Light") {
    let recipe = PreviewData.recipe
    let data = (try? SharedRecipeFile(recipe: recipe).fileData()) ?? Data()
    return NavigationStack { SharedRecipePreview(data: data) { _ in } }
        .modelContainer(PreviewData.container)
        .environment(AssistantProvider())
}

#Preview("Dark, not a recipe") {
    NavigationStack { SharedRecipePreview(data: Data("hello".utf8)) { _ in } }
        .modelContainer(PreviewData.container)
        .environment(AssistantProvider())
        .preferredColorScheme(.dark)
}
