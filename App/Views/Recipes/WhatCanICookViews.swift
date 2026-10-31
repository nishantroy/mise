import SwiftUI
import RecipeKit

/// "What can I cook?": the ask card at the top of the Recipes tab. Multi-line so dictation
/// (the keyboard's mic) can run on; return or the arrow button submits.
struct CookAskCard: View {
    @Binding var text: String
    var isRefining: Bool
    var onSubmit: () -> Void
    var onClear: () -> Void
    @FocusState private var focused: Bool

    static let examples = ["Something quick", "Spicy noodles", "With what I have", "Use up chicken"]

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        MiseCard(padding: Theme.Spacing.s) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .foregroundStyle(Color.mise.accent)
                        .padding(.top, 10)
                        .accessibilityHidden(true)
                    TextField("What can I cook? e.g. spicy, ground beef, under 30 min", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Color.mise.ink)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.search)
                        .focused($focused)
                        .padding(.vertical, 10)
                        .onSubmit(submit)
                        // A vertical field inserts return as a newline; treat it as submit.
                        .onChange(of: text) { _, new in
                            guard new.contains("\n") else { return }
                            text = new.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                            submit()
                        }
                        .accessibilityLabel("What can I cook?")
                        .accessibilityIdentifier("cook.ask.field")
                    if !isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill") {
                            onClear()
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.mise.inkSecondary)
                        .frame(minWidth: Theme.Size.minTap, minHeight: Theme.Size.minTap)
                        .accessibilityIdentifier("cook.ask.clear")
                    }
                    Button("Find recipes", systemImage: "arrow.up.circle.fill", action: submit)
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .foregroundStyle(isEmpty ? Color.mise.inkSecondary : Color.mise.accent)
                        .frame(minWidth: Theme.Size.minTap, minHeight: Theme.Size.minTap)
                        .disabled(isEmpty)
                        .accessibilityIdentifier("cook.ask.submit")
                }
                .padding(.horizontal, Theme.Spacing.xs)
                .background(Color.mise.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))

                if isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Spacing.xs) {
                            ForEach(Self.examples, id: \.self) { example in
                                Button(example) {
                                    text = example
                                    submit()
                                }
                                .font(Theme.Fonts.meta)
                                .foregroundStyle(Color.mise.ink)
                                .padding(.horizontal, Theme.Spacing.s)
                                .frame(minHeight: Theme.Size.minTap)
                                .background(Color.mise.surfaceSunken, in: Capsule())
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .accessibilityLabel("Examples")
                } else if isRefining {
                    HStack(spacing: Theme.Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Reading your question…")
                    }
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color.mise.inkSecondary)
                    .accessibilityIdentifier("cook.refining")
                }
            }
        }
    }

    private func submit() {
        guard !isEmpty else { return }
        focused = false
        onSubmit()
    }
}

/// Ranked results under the ask card.
struct CookResultsView: View {
    let result: CookSearchResult
    let imageURL: (UUID) -> URL?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if !result.query.summary.isEmpty {
                understood
            }
            switch result.status {
            case .noRecipes:
                EmptyState(systemImage: "book.closed", title: "No recipes yet",
                           message: "Save a few recipes and Mise will find the best one for tonight.")
            case .matched:
                Text(result.matches.count == 1 ? "Best match" : "Best matches")
                    .serifTitle(Theme.Fonts.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                if !result.unmatchedIngredients.isEmpty {
                    note("None of your recipes use \(Self.list(result.unmatchedIngredients)).")
                }
                ForEach(Array(result.matches.enumerated()), id: \.element.id) { index, match in
                    card(match, isBest: index == 0 && result.matches.count > 1)
                }
            case .closeOnly:
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Nothing fits everything")
                        .serifTitle(Theme.Fonts.sectionTitle)
                        .accessibilityAddTraits(.isHeader)
                    if !result.relaxed.isEmpty {
                        note("Closest matches, without: \(result.relaxed.joined(separator: ", ")).")
                            .accessibilityIdentifier("cook.relaxed")
                    }
                }
                ForEach(result.closeMatches) { match in
                    card(match, isBest: false)
                        .accessibilityIdentifier("cook.close")
                }
            }
        }
    }

    private var understood: some View {
        FlowLayout(spacing: Theme.Spacing.xs) {
            ForEach(result.query.summary, id: \.self) { item in
                Text(item)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color.mise.ink)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .background(Color.mise.surfaceSunken, in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Looking for: \(result.query.summary.joined(separator: ", "))")
        .accessibilityIdentifier("cook.understood")
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
    }

    private func card(_ match: CookMatch, isBest: Bool) -> some View {
        NavigationLink(value: match.id) {
            CookMatchCard(match: match, imageURL: imageURL(match.id), isBest: isBest)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cook.result")
    }

    static func list(_ items: [String]) -> String {
        items.count <= 1 ? items.joined() : items.dropLast().joined(separator: ", ") + " or " + (items.last ?? "")
    }
}

struct CookMatchCard: View {
    let match: CookMatch
    let imageURL: URL?
    var isBest = false

    var body: some View {
        MiseCard(padding: Theme.Spacing.s) {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                RecipeImage(url: imageURL)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    if isBest { Badge(title: "Best match", systemImage: "star.fill", tone: Color.mise.accent) }
                    Text(match.title)
                        .serifTitle(Theme.Fonts.sectionTitle)
                        .multilineTextAlignment(.leading)
                    Text(match.why)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Color.mise.inkSecondary)
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("cook.why")
                    if match.hasEverything {
                        Badge(title: "From your pantry", systemImage: "checkmark")
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview("Results, light") {
    let candidates = [PreviewData.recipe, PreviewData.guessedRecipe].map { CookCandidate(id: UUID(), recipe: $0) }
    let result = RecipeMatcher().search(CookQueryParser().parse("something spicy with chicken under 45 min"),
                                        in: candidates, pantry: .empty)
    return NavigationStack {
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                CookAskCard(text: .constant("something spicy with chicken under 45 min"), isRefining: true, onSubmit: {}, onClear: {})
                CookResultsView(result: result) { _ in nil }
            }
            .padding(Theme.Spacing.gutter)
        }
        .miseScreenBackground()
    }
}

#Preview("Empty ask, dark") {
    CookAskCard(text: .constant(""), isRefining: false, onSubmit: {}, onClear: {})
        .padding(Theme.Spacing.gutter)
        .miseScreenBackground()
        .preferredColorScheme(.dark)
}
