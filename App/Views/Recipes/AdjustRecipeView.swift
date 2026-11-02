import SwiftUI
import SwiftData
import RecipeKit

/// "I made this": rating, quick chips, free-text feedback, and assistant-proposed edits
/// the user can untick before saving. In `.change` mode ("Change recipe") it is only the text
/// and the proposals: no rating, photo or cook-mode swaps, and saving doesn't log a cook.
struct AdjustRecipeView: View {
    enum Mode {
        /// "I made this": a report of a cook, logged with the revision.
        case cooked
        /// "Change recipe": instructions for the saved recipe; nothing is logged.
        case change

        var feedbackKind: FeedbackKind { self == .cooked ? .cooked : .change }
    }

    let saved: SavedRecipe
    var mode: Mode = .cooked
    /// Swaps made in cook mode ("I'm out of X"), offered unticked so the recipe only changes
    /// if the cook chooses.
    var sessionSwaps: [CookSwap] = []
    /// The servings shown when cooking (logged with the cook).
    var servingsCooked: Int? = nil
    /// Called after saving.
    var onSaved: () -> Void = {}

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
    /// A proposed step being reworded by hand.
    @State private var editingStep: StepEditTarget?
    /// An unresolved note being turned into a step or ingredient change by hand.
    @State private var changingInstead: ChangeInsteadTarget?
    @State private var assistantName = ""
    @State private var keptSwaps: [KeptSwap] = []
    /// Downscaled in memory; written with the log entry on save.
    @State private var photo: ProcessedCookPhoto?
    /// "make it serve 6": not a saved change, so the proposals say where servings are set.
    @State private var servingsAsked: Int?

    /// A cook-mode swap and the edits that would keep it in the saved recipe.
    struct KeptSwap: Identifiable {
        let id: UUID
        let label: String
        let edits: [RecipeEdit]
        var included = false
    }

    static let quickChips = ["Too salty", "Too spicy", "Too bland", "Needed more time", "Perfect"]

    /// Examples under the "Change recipe" field.
    static let changeExamples = ["use 2 tbsp oil", "cook the chicken 10 min on high", "no green chillies", "skip the dry-out step", "it's usually too salty"]

    private var isCooked: Bool { mode == .cooked }

    private var feedback: String {
        let chipText = Self.quickChips.filter { chips.contains($0) && $0 != "Perfect" }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (chipText + (typed.isEmpty ? [] : [typed])).joined(separator: ". ")
    }

    /// "Change recipe" saves only what was chosen from suggestions for the text as it is now, so
    /// nothing becomes a note without the cook picking "Save as note". ("I made this" can always save.)
    private var canSaveChange: Bool {
        guard !isCooked else { return true }
        let chosen = !(proposals ?? []).chosenEdits.isEmpty
        if feedback.isEmpty { return chosen }
        return proposals != nil && proposedFor == feedback && chosen
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text(isCooked ? "How did it go?" : "What do you want to change?")
                    .serifTitle(Theme.Fonts.header).accessibilityAddTraits(.isHeader)
                Text(saved.title).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)

                if isCooked {
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

                    CookPhotoSection(photo: $photo)
                }

                MiseCard {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        if isCooked {
                            Text("What did you change?").font(.headline).foregroundStyle(Color.mise.ink)
                        } else {
                            Text("Say it in your own words, e.g. " + Self.changeExamples.map { "“\($0)”" }.joined(separator: ", ") + ".")
                                .font(Theme.Fonts.meta)
                                .foregroundStyle(Color.mise.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        TextField(isCooked ? "e.g. used chicken thighs instead of breast, needed 10 more minutes" : "e.g. use less salt and more garlic",
                                  text: $text, axis: .vertical)
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

                if isCooked, !keptSwaps.isEmpty { swapsCard }

                if let proposals {
                    proposalsCard(proposals)
                }

                // Wrote up the version you actually made (or want)? Diff it against this recipe instead.
                NavigationLink {
                    PasteMyVersionView(saved: saved, markCooked: isCooked, cookPhoto: isCooked ? photo : nil) { dismiss() }
                } label: {
                    Label(isCooked ? "Paste your own version instead" : "Paste a whole new version instead", systemImage: "doc.on.clipboard")
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
                // A change with nothing to change has nothing to save ("I made this" logs the cook).
                .disabled(!canSaveChange)
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.vertical, Theme.Spacing.s)
                .background(Color.mise.background)
                .accessibilityIdentifier("adjust.save")
        }
        .navigationTitle(isCooked ? "I made this" : "Change recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .onAppear {
            rating = saved.rating ?? 0
            if isCooked, keptSwaps.isEmpty {
                let base = saved.recipe
                keptSwaps = sessionSwaps.compactMap { swap in
                    let edits = swap.recipeEdits(in: base)
                    return edits.isEmpty ? nil : KeptSwap(id: swap.id, label: swap.label, edits: edits)
                }
            }
        }
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

    private var swapsCard: some View {
        SectionCard(title: "While cooking") {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach($keptSwaps) { $kept in
                    Toggle(isOn: $kept.included) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text("Keep this swap in the recipe?").foregroundStyle(Color.mise.ink)
                            Text(kept.label).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .tint(Color.mise.accent)
                    .accessibilityIdentifier("adjust.keepSwap")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("adjust.sessionSwaps")
    }

    private func proposalsCard(_ list: [EditProposal]) -> some View {
        SectionCard(title: "Suggested changes") {
            if let servingsAsked {
                // No edit stores servings; the stepper on the recipe scales the amounts.
                Label("To make it for \(servingsAsked), use Servings on the recipe: the amounts scale as you cook.",
                      systemImage: "person.2")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Color.mise.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("adjust.servingsHint")
            }
            if list.isEmpty {
                if servingsAsked == nil {
                    Text(isCooked ? "No changes to suggest. Your feedback will be saved as a note."
                                  : "Nothing here changes the recipe.")
                        .foregroundStyle(Color.mise.inkSecondary)
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, proposal in
                        let isOn = Binding(get: { proposals?[index].included ?? false },
                                           set: { proposals?.setIncluded($0, at: index) })
                        if let rewrite = proposal.rewrite {
                            // Step changes: before/after, tap the text to word it yourself.
                            StepChangeRow(rewrite: rewrite, isOn: isOn, isAvailable: list.isAvailable(proposal),
                                          identifier: rewrite.fromFeedback ? "adjust.step.\(rewrite.stepIndex)" : "adjust.rewrite.\(rewrite.stepIndex)") {
                                editStep(rewrite.stepIndex, proposal: index, current: rewrite.removesStep ? rewrite.oldText : rewrite.newText)
                            }
                        } else if let note = proposal.unresolved, !isCooked {
                            // Nothing could turn it into a change: the cook chooses, nothing is ticked.
                            UnresolvedNoteRow(note: note, isOn: isOn, identifier: "adjust.unresolved.\(index)") {
                                changingInstead = ChangeInsteadTarget(proposalIndex: index, note: note)
                            }
                        } else {
                            ProposalToggle(text: proposal.summary, isOn: isOn, identifier: "adjust.edit.\(index)")
                            if let said = proposal.said {
                                Text("You said: “\(said)”").font(Theme.Fonts.caption).foregroundStyle(Color.mise.inkSecondary)
                            }
                            if let step = proposal.noteStep {
                                // The rules (and the model) couldn't write it into the step: do it by hand.
                                Button("Edit step \(step + 1) instead", systemImage: "pencil") {
                                    editStep(step, proposal: index, current: nil)
                                }
                                .font(Theme.Fonts.meta)
                                .tint(Color.mise.accent)
                                .accessibilityIdentifier("adjust.editStep.\(step)")
                            } else if let note = proposal.unresolved {
                                // "I made this" keeps the note ticked, but a change can be made instead.
                                Button("Change the recipe instead", systemImage: "pencil") {
                                    changingInstead = ChangeInsteadTarget(proposalIndex: index, note: note)
                                }
                                .font(Theme.Fonts.meta)
                                .tint(Color.mise.accent)
                                .frame(minHeight: Theme.Size.minTap)
                                .accessibilityIdentifier("adjust.changeInstead.\(index)")
                            }
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
        .sheet(item: $editingStep) { target in
            StepEditSheet(title: "Step \(target.stepIndex + 1)", original: target.original, initial: target.initial) { text in
                if let index = target.proposalIndex { proposals?.setStepText(text, at: index, original: target.original) }
            }
        }
        .sheet(item: $changingInstead) { target in
            let recipe = saved.recipe
            ChangeInsteadSheet(note: target.note, recipe: recipe) { step, text in
                proposals?.setStepText(text, at: target.proposalIndex, original: recipe.steps[step], step: step)
            } onIngredient: { edit in
                proposals?.resolve(at: target.proposalIndex, with: edit, recipe: recipe)
            }
        }
    }

    /// Opens the step editor for a proposal, starting from its new text (or the saved step).
    private func editStep(_ step: Int, proposal index: Int, current: String?) {
        let steps = saved.recipe.steps
        guard steps.indices.contains(step) else { return }
        editingStep = StepEditTarget(proposalIndex: index, stepIndex: step, original: steps[step], initial: current ?? steps[step])
    }

    // MARK: Actions

    private func suggest() {
        let feedback = feedback
        guard !feedback.isEmpty else { return }
        let recipe = saved.recipe
        let prefs = context.profile().prefs
        let assistant = provider.assistant
        let kind = mode.feedbackKind
        isThinking = true
        Task {
            var edits: [RecipeEdit]
            var name = assistant.displayName
            do {
                edits = try await assistant.proposeEdits(recipe: recipe, feedback: feedback, kind: kind, prefs: prefs)
            } catch {
                let rules = RuleBasedAssistant()
                edits = (try? await rules.proposeEdits(recipe: recipe, feedback: feedback, kind: kind, prefs: prefs)) ?? []
                name = rules.displayName
            }
            // Step changes from the feedback show a before/after (the rules found the steps).
            let analysis = FeedbackParser(kind: kind).analyse(feedback, recipe: recipe)
            let base = [EditProposal].feedback(edits, recipe: recipe, changes: analysis.stepChanges, analysis: analysis, kind: kind)
            proposals = base
            servingsAsked = kind == .change ? analysis.servings : nil
            proposedFor = feedback
            assistantName = name
            isThinking = false

            // The model may reword one step per edit (an added ingredient no step mentions, a swap
            // that reads awkwardly; offered unticked, after the edits) and write feedback the rules
            // could only note into its step (replacing the note, ticked). The rules offer none.
            guard !edits.isEmpty else { return }
            isRewording = true
            let rewrites = (try? await assistant.proposeStepRewrites(recipe: recipe, edits: edits, feedback: feedback, kind: kind)) ?? []
            isRewording = false
            guard proposedFor == feedback, !rewrites.isEmpty, var current = proposals else { return }
            current.add(rewrites, base: base)
            proposals = current
        }
    }

    private func save() {
        // Kept cook-mode swaps first, then the feedback's edits.
        var edits = (isCooked ? keptSwaps.filter(\.included).flatMap(\.edits) : []) + (proposals ?? []).chosenEdits
        // Feedback typed but never turned into suggestions is kept as a note, so nothing is lost
        // (unless all it asked for was a serving size, which the hint already answered).
        let pending = feedback
        if !pending.isEmpty && (proposals == nil || pending != proposedFor) {
            edits.append(.addNote(pending))
        } else if let proposals, proposals.isEmpty, !pending.isEmpty, servingsAsked == nil {
            edits.append(.addNote(pending))
        }
        guard isCooked else {
            // "Change recipe": a revision only, no cook logged, no rating.
            if !edits.isEmpty {
                saved.apply(edits, summary: "Changed: " + edits.summary(in: saved.recipe))
                try? context.save()
            }
            onSaved()
            dismiss()
            return
        }
        let summary = edits.isEmpty ? "Cooked it" : "Cooked it: " + edits.summary(in: saved.recipe)
        saved.apply(edits, summary: summary)
        if ratingTouched {
            saved.rating = rating == 0 ? nil : rating
        } else if chips.contains("Perfect") {
            saved.rating = 1
        }
        // Counts the cook (timesCooked) and links the revision just saved.
        CookLogging.record(saved, photo: photo, rating: saved.rating, feedback: pending,
                           servings: servingsCooked, revisionID: saved.revisions.last?.id)
        try? context.save()
        onSaved()
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

#Preview("Change recipe, light") {
    let container = PreviewData.container
    let saved = try! container.mainContext.fetch(FetchDescriptor<SavedRecipe>()).first!
    return NavigationStack { AdjustRecipeView(saved: saved, mode: .change) }
        .modelContainer(container)
        .environment(AssistantProvider())
}

#Preview("Change recipe, dark") {
    let container = PreviewData.container
    let saved = try! container.mainContext.fetch(FetchDescriptor<SavedRecipe>()).first!
    return NavigationStack { AdjustRecipeView(saved: saved, mode: .change) }
        .modelContainer(container)
        .environment(AssistantProvider())
        .preferredColorScheme(.dark)
}
