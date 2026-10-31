import SwiftUI
import RecipeKit

/// Paste a link (or recipe text), fetch and parse it, then go to the ingredient check.
struct ImportView: View {
    enum Mode: String, CaseIterable { case link = "Link", text = "Text" }

    var initialURL: URL?
    var onSaved: (SavedRecipe) -> Void

    @Environment(\.recipeFetcher) private var fetcher
    @Environment(AssistantProvider.self) private var provider
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .link
    @State private var urlText = ""
    @State private var pastedText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var parsed: Recipe?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                Text("Add a recipe").serifTitle(Theme.Fonts.header).accessibilityAddTraits(.isHeader)

                Picker("Source", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("import.mode")

                MiseCard {
                    if mode == .link { linkInput } else { textInput }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Color.mise.conflict)
                        .accessibilityIdentifier("import.error")
                }
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.top, Theme.Spacing.m)
        }
        .scrollDismissesKeyboard(.interactively)
        .miseScreenBackground()
        .safeAreaInset(edge: .bottom) {
            Button(action: runImport) {
                if isLoading { ProgressView().tint(Color.mise.onAccent) } else { Text("Import") }
            }
            .buttonStyle(.misePrimary)
            .disabled(!canImport || isLoading)
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.s)
            .background(Color.mise.background)
            .accessibilityIdentifier("import.go")
        }
        .navigationTitle("Import")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .navigationDestination(item: $parsed) { recipe in
            IngredientCheckView(recipe: recipe, existing: nil) { saved in onSaved(saved) }
        }
        .onAppear {
            if let initialURL, urlText.isEmpty { urlText = initialURL.absoluteString }
        }
    }

    private var linkInput: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Recipe link").font(.headline).foregroundStyle(Color.mise.ink)
            TextField("https://…", text: $urlText)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(runImport)
                .padding(.horizontal, Theme.Spacing.s)
                .frame(minHeight: Theme.Size.minTap)
                .background(Color.mise.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .accessibilityIdentifier("import.url")
            // PasteButton reads the clipboard only when tapped, so iOS doesn't show the paste prompt.
            PasteButton(payloadType: URL.self) { urls in
                if let url = urls.first { urlText = url.absoluteString }
            }
            .buttonBorderShape(.capsule)
            .tint(Color.mise.accent)
            Text("Or share a page from Safari: Share → Mise.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color.mise.inkSecondary)
        }
    }

    private var textInput: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Recipe text").font(.headline).foregroundStyle(Color.mise.ink)
            TextEditor(text: $pastedText)
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(Theme.Spacing.xs)
                .background(Color.mise.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .accessibilityIdentifier("import.text")
            Text("Paste the title, an \"Ingredients\" list and a \"Method\" or \"Instructions\" list.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color.mise.inkSecondary)
        }
    }

    private var canImport: Bool {
        switch mode {
        case .link: normalisedURL != nil
        case .text: !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var normalisedURL: URL? {
        var text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        return url
    }

    /// Cuisine guess and time estimate, computed once at import and stored on the recipe.
    private func withInsights(_ recipe: Recipe) async -> Recipe {
        await RecipeInsights.enrich(recipe, using: provider.assistant)
    }

    private func runImport() {
        errorMessage = nil
        switch mode {
        case .text:
            guard let recipe = RecipeImporter.parse(text: pastedText) else {
                errorMessage = "Couldn't find a recipe in that text. Make sure it has an \"Ingredients\" heading and a \"Method\" or \"Instructions\" heading."
                return
            }
            isLoading = true
            Task {
                defer { isLoading = false }
                parsed = await withInsights(recipe)
            }
        case .link:
            guard let url = normalisedURL else {
                errorMessage = "That doesn't look like a web link."
                return
            }
            isLoading = true
            Task {
                defer { isLoading = false }
                do {
                    let html = try await fetcher.fetchHTML(from: url)
                    if let recipe = RecipeImporter.parse(html: html, url: url) {
                        parsed = await withInsights(recipe)
                    } else {
                        errorMessage = "Couldn't find a recipe on that page. Try the Text tab and paste the recipe instead."
                    }
                } catch {
                    errorMessage = "Couldn't load that page. \(error.localizedDescription)"
                }
            }
        }
    }
}

#Preview("Light") {
    NavigationStack {
        ImportView(initialURL: URL(string: "https://example.com/recipe")) { _ in }
    }
    .modelContainer(PreviewData.container)
    .environment(AssistantProvider())
    .environment(\.recipeFetcher, StubRecipeFetcher(pages: [:]))
}

#Preview("Dark") {
    NavigationStack {
        ImportView { _ in }
    }
    .modelContainer(PreviewData.container)
    .environment(AssistantProvider())
    .preferredColorScheme(.dark)
}
