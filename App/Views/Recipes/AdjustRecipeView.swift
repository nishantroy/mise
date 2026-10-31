import SwiftUI
import SwiftData
import RecipeKit

/// "I made this": rating, quick chips, free-text feedback, and assistant-proposed edits
/// the user can untick before saving.
struct AdjustRecipeView: View {
    let saved: SavedRecipe

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AssistantProvider.self) private var provider
    @State private var rating: Int = 0
    /// Whether the user tapped a thumb in this session (so deselecting can clear the rating).
    @State private var ratingTouched = false
    @State private var chips: Set<String> = []
    @State private var text = ""
    @State private var proposals: [EditProposal]?
    /// The feedback the current proposals were made from.
    @State private var proposedFor = ""
    @State private var isThinking = false
    /// Waiting for the model's step rewrites (shown below the edits).
    @State private var isRewording = false
    @State private var assistantName = ""

    static let quickChips = ["Too salty", "Too spicy", "Too bland", "Needed more time", "Perfect"]

    private var feedback: String {
        let chipText = Self.quickChips.filter { chips.contains($0) && $0 != "Perfect" }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (chipText + (typed.isEmpty ? [] : [typed])).joined(separator: ". ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("How did it go?").serifTitle(Theme.Fonts.header).accessibilityAddTraits(.isHeader)
                Text(saved.title).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)

                MiseCard {
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        HStack(spacing: Theme.Spacing.s) {
                            thumb(1, symbol: "hand.thumbsup", label: "Liked it")
                            thumb(-1, symbol: "hand.thumbsdown", label: "Didn't like it")
                        }
                        ChipGroup(items: Self.quickChips, title: { $0 }, isSelected: { chips.contains($0) },
                                  toggle: { c in if chips.contains(c) { chips.remove(c) } else { chips.insert(c) } },
                                  identifier: { "adjust.chip.\($0)" })
                    }
                }

                MiseCard {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text("What did you change?").font(.headline).foregroundStyle(Color.mise.ink)
                        TextField("e.g. used chicken thighs instead of breast, needed 10 more minutes", text: $text, axis: .vertical)
                            .lineLimit(3...8)
                            .padding(Theme.Spacing.s)
                            .background(Color.mise.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                            .accessibilityIdentifier("adjust.text")
                        Button(action: suggest) {
                            if isThinking { ProgressView() } else { Label("Suggest changes", systemImage: "wand.and.stars") }
                        }
                        .buttonStyle(.miseSecondaryWide)
                        .disabled(feedback.isEmpty || isThinking)
                        .accessibilityIdentifier("adjust.suggest")
                    }
                }

                if let proposals {
                    proposalsCard(proposals)
                }

                // Wrote up the version you actually made? Diff it against this recipe instead.
                NavigationLink {
                    PasteMyVersionView(saved: saved, markCooked: true) { dismiss() }
                } label: {
                    Label("Paste your own version instead", systemImage: "doc.on.clipboard")
                        .font(Theme.Fonts.meta)
                        .frame(minHeight: Theme.Size.minTap)
                }
                .tint(Color.mise.accent)
                .accessibilityIdentifier("adjust.pasteMyVersion")
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.m)
        }
        .scrollDismissesKeyboard(.interactively)
        .miseScreenBackground()
        .safeAreaInset(edge: .bottom) {
            Button("Save", action: save)
                .buttonStyle(.misePrimary)
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.vertical, Theme.Spacing.s)
                .background(Color.mise.background)
                .accessibilityIdentifier("adjust.save")
        }
        .navigationTitle("I made this")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .onAppear { rating = saved.rating ?? 0 }
    }

    private func thumb(_ value: Int, symbol: String, label: String) -> some View {
        let selected = rating == value
        return Button {
            rating = selected ? 0 : value
            ratingTouched = true
        } label: {
            Label(label, systemImage: selected ? symbol + ".fill" : symbol)
                .font(Theme.Fonts.meta)
                .padding(.horizontal, Theme.Spacing.s)
                .frame(minHeight: Theme.Size.minTap)
                .foregroundStyle(selected ? Color.mise.onAccent : Color.mise.ink)
                .background(selected ? Color.mise.accent : Color.mise.surfaceSunken, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(value > 0 ? "adjust.thumbsUp" : "adjust.thumbsDown")
    }

    private func proposalsCard(_ list: [EditProposal]) -> some View {
        SectionCard(title: "Suggested changes") {
            if list.isEmpty {
                Text("No changes to suggest. Your feedback will be saved as a note.")
                    .foregroundStyle(Color.mise.inkSecondary)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, proposal in
                        let isOn = Binding(get: { proposals?[index].included ?? false },
                                           set: { proposals?.setIncluded($0, at: index) })
                        if let rewrite = proposal.rewrite {
                            RewriteToggle(rewrite: rewrite, isOn: isOn, isAvailable: list.isAvailable(proposal),
                                          identifier: "adjust.rewrite.\(rewrite.stepIndex)")
                        } else {
                            ProposalToggle(text: proposal.summary, isOn: isOn, identifier: "adjust.edit.\(index)")
                        }
                    }
                    if isRewording {
                        HStack(spacing: Theme.Spacing.xs) {
                            ProgressView()
                            Text("Checking whether any step needs rewording…")
                        }
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Color.mise.inkSecondary)
                    }
                    Text("Untick anything you don't want. Suggested by \(assistantName).")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Color.mise.inkSecondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("adjust.proposals")
    }

    // MARK: Actions

    private func suggest() {
        let feedback = feedback
        guard !feedback.isEmpty else { return }
        let recipe = saved.recipe
        let prefs = context.profile().prefs
        let assistant = provider.assistant
        isThinking = true
        Task {
            var edits: [RecipeEdit]
            var name = assistant.displayName
            do {
                edits = try await assistant.proposeEdits(recipe: recipe, feedback: feedback, prefs: prefs)
            } catch {
                let rules = RuleBasedAssistant()
                edits = (try? await rules.proposeEdits(recipe: recipe, feedback: feedback, prefs: prefs)) ?? []
                name = rules.displayName
            }
            let base = edits.map { EditProposal(edit: $0, summary: $0.summary(in: recipe)) }
            proposals = base
            proposedFor = feedback
            assistantName = name
            isThinking = false

            // The model may reword one step per edit (an added ingredient no step mentions, a swap
            // that reads awkwardly). Offered unticked, after the edits; the rules offer none.
            guard !edits.isEmpty else { return }
            isRewording = true
            let rewrites = (try? await assistant.proposeStepRewrites(recipe: recipe, edits: edits, feedback: feedback)) ?? []
            isRewording = false
            guard proposedFor == feedback, !rewrites.isEmpty, var current = proposals else { return }
            current += [EditProposal].rewrites(rewrites, dependingOn: base)
            proposals = current
        }
    }

    private func save() {
        var edits = (proposals ?? []).chosenEdits
        // Feedback typed but never turned into suggestions is kept as a note, so nothing is lost.
        let pending = feedback
        if !pending.isEmpty && (proposals == nil || pending != proposedFor) {
            edits.append(.addNote(pending))
        } else if let proposals, proposals.isEmpty, !pending.isEmpty {
            edits.append(.addNote(pending))
        }
        let summary = edits.isEmpty ? "Cooked it" : "Cooked it: " + edits.summary(in: saved.recipe)
        saved.apply(edits, summary: summary)
        saved.timesCooked += 1
        if ratingTouched {
            saved.rating = rating == 0 ? nil : rating
        } else if chips.contains("Perfect") {
            saved.rating = 1
        }
        try? context.save()
        dismiss()
    }
}

#Preview("Light") {
    let container = PreviewData.container
    let saved = try! container.mainContext.fetch(FetchDescriptor<SavedRecipe>()).first!
    return NavigationStack { AdjustRecipeView(saved: saved) }
        .modelContainer(container)
        .environment(AssistantProvider())
}

#Preview("Dark, largest text") {
    let container = PreviewData.container
    let saved = try! container.mainContext.fetch(FetchDescriptor<SavedRecipe>()).first!
    return NavigationStack { AdjustRecipeView(saved: saved) }
        .modelContainer(container)
        .environment(AssistantProvider())
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility5)
}
