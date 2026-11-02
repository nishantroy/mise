import SwiftUI
import SwiftData
import RecipeKit

/// "Paste my version": paste the recipe as you actually made it, compare it with the saved one,
/// untick anything you don't want (edits, title, servings, pantry updates), and save it as a
/// "Your version" revision. The imported original is kept for "Reset to original".
struct PasteMyVersionView: View {
    let saved: SavedRecipe
    /// Prefilled text (from the share extension); compared straight away.
    var initialText: String = ""
    /// Reached from "I made this": saving also counts as a cook.
    var markCooked = false
    var onSaved: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(AssistantProvider.self) private var provider
    @State private var text = ""
    @State private var comparedText: String?
    @State private var isComparing = false
    @State private var errorMessage: String?
    @State private var diff: RecipeDiff?
    @State private var proposals: [EditProposal] = []
    @State private var pantry: [PantryProposal] = []
    @State private var useTitle = false
    @State private var useServings = true
    @State private var didPrefill = false

    private var canSave: Bool { diff != nil && comparedText == text && !isComparing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("Your version").serifTitle(Theme.Fonts.header).accessibilityAddTraits(.isHeader)
                Text(saved.title).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)

                inputCard

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Color.mise.conflict)
                        .accessibilityIdentifier("myVersion.error")
                }

                if let diff {
                    changesCard(diff)
                }
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.m)
        }
        .scrollDismissesKeyboard(.interactively)
        .miseScreenBackground()
        .safeAreaInset(edge: .bottom) {
            Button("Save", action: save)
                .buttonStyle(.misePrimary)
                .disabled(!canSave)
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.vertical, Theme.Spacing.s)
                .background(Color.mise.background)
                .accessibilityIdentifier("myVersion.save")
        }
        .navigationTitle("Paste my version")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !didPrefill else { return }
            didPrefill = true
            if !initialText.isEmpty {
                text = initialText
                compare()
            }
        }
    }

    private var inputCard: some View {
        MiseCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("What you actually made").font(.headline).foregroundStyle(Color.mise.ink)
                TextEditor(text: $text)
                    // Capped so a long paste scrolls inside the box and Compare stays put.
                    .frame(minHeight: 180, maxHeight: 300)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Spacing.xs)
                    .background(Color.mise.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .accessibilityIdentifier("myVersion.text")
                // PasteButton reads the clipboard only when tapped, so iOS doesn't show the paste prompt.
                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first { text = first }
                }
                .buttonBorderShape(.capsule)
                .tint(Color.mise.accent)
                .accessibilityIdentifier("myVersion.paste")
                Text("A title, then your steps with amounts in them, or an Ingredients list and a Method.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color.mise.inkSecondary)
                Button(action: compare) {
                    if isComparing { ProgressView() } else { Label("Compare", systemImage: "arrow.left.arrow.right") }
                }
                .buttonStyle(.miseSecondaryWide)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isComparing)
                .accessibilityIdentifier("myVersion.compare")
            }
        }
    }

    private func changesCard(_ diff: RecipeDiff) -> some View {
        SectionCard(title: "Changes") {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if proposals.isEmpty && diff.title == nil && diff.servings == nil && pantry.isEmpty {
                    Text("Your version matches this recipe.").foregroundStyle(Color.mise.inkSecondary)
                }
                ForEach(Array(proposals.enumerated()), id: \.element.id) { index, proposal in
                    ProposalToggle(text: proposal.summary,
                                   isOn: Binding(get: { proposals.indices.contains(index) && proposals[index].included },
                                                 set: { if proposals.indices.contains(index) { proposals[index].included = $0 } }),
                                   identifier: "myVersion.edit.\(index)")
                    if case let .replaceSteps(steps) = proposal.edit {
                        stepsPreview(steps)
                    }
                }
                if let warning = diff.stepsWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Color.mise.conflict)
                        .accessibilityIdentifier("myVersion.stepsWarning")
                }
                if let servings = diff.servings {
                    ProposalToggle(text: "Serves \(servings)" + (saved.recipe.servings.map { " (was \($0))" } ?? ""),
                                   isOn: $useServings, identifier: "myVersion.servings")
                }
                if let title = diff.title {
                    ProposalToggle(text: "Rename to “\(title)”", isOn: $useTitle, identifier: "myVersion.title")
                }
                if !pantry.isEmpty {
                    Divider().overlay(Color.mise.divider).padding(.vertical, Theme.Spacing.xxs)
                    ForEach(Array(pantry.enumerated()), id: \.element.id) { index, row in
                        ProposalToggle(text: row.update.summary,
                                       isOn: Binding(get: { pantry.indices.contains(index) && pantry[index].included },
                                                     set: { if pantry.indices.contains(index) { pantry[index].included = $0 } }),
                                       identifier: "myVersion.pantry.\(index)")
                    }
                }
                Text(comparedText == text
                     ? "Untick anything you don't want. The imported recipe stays saved, so Reset to original brings it back."
                     : "You've edited the text. Compare again before saving.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color.mise.inkSecondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("myVersion.changes")
    }

    /// The first few of the new steps under "Use your steps (N steps)", so a bad parse (an
    /// ingredient list read as steps) shows before saving.
    private func stepsPreview(_ steps: [String]) -> some View {
        let shown = steps.prefix(3)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            ForEach(Array(shown.enumerated()), id: \.offset) { offset, step in
                Text("\(offset + 1). \(step)").lineLimit(2)
            }
            if steps.count > shown.count {
                Text("…and \(steps.count - shown.count) more, ending “\(steps[steps.count - 1])”").lineLimit(2)
            }
        }
        .font(Theme.Fonts.caption)
        .foregroundStyle(Color.mise.inkSecondary)
        .padding(.leading, Theme.Spacing.s)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("myVersion.stepsPreview")
    }

    // MARK: Actions

    private func compare() {
        let pasted = text
        guard !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        errorMessage = nil
        isComparing = true
        let current = saved.recipe
        let pantrySnapshot = context.pantrySnapshot()
        let assistant = provider.assistant
        Task {
            defer { isComparing = false }
            guard let parsed = await PastedRecipes.parsePasted(pasted, assistant: assistant) else {
                diff = nil
                errorMessage = "Couldn't read a recipe in that text. Put amounts in the steps (\"1 tbsp soy sauce\"), or use an \"Ingredients\" heading and a \"Method\" heading."
                return
            }
            let result = RecipeDiff.compare(current: current, mine: parsed.recipe, pantry: pantrySnapshot,
                                            servingsRange: parsed.servingsRange)
            proposals = result.edits.map { EditProposal(edit: $0, summary: $0.summary(in: current)) }
            pantry = result.pantryUpdates.map { PantryProposal(update: $0) }
            useTitle = false
            useServings = true
            diff = result
            comparedText = pasted
        }
    }

    private func save() {
        guard let diff, canSave else { return }
        let ticked = proposals.filter(\.included)
        let title = useTitle ? diff.title : nil
        let servings = useServings ? diff.servings : nil
        var parts = ticked.map(\.summary)
        if let servings { parts.append("Serves \(servings)") }
        if let title { parts.append("Renamed to \(title)") }
        let summary = parts.isEmpty ? "Your version" : "Your version: " + parts.joined(separator: "; ")
        saved.applyVersion(ticked.map(\.edit), title: title, servings: servings, summary: summary)
        for row in pantry where row.included {
            context.setPantry(key: row.update.key, displayName: row.update.displayName,
                              status: row.update.status == .have ? .have : .missing)
        }
        if markCooked { saved.timesCooked += 1 }
        try? context.save()
        onSaved()
    }
}

#Preview("Light") {
    let container = PreviewData.container
    let saved = try! container.mainContext.fetch(FetchDescriptor<SavedRecipe>()).first!
    return NavigationStack {
        PasteMyVersionView(saved: saved, initialText: "My Kung Pao (serves 2)\nFry 2 tbsp peanuts in 1 tbsp oil.\nAdd 300 g chicken and 1 tbsp soy sauce.") {}
    }
    .modelContainer(container)
    .environment(AssistantProvider())
}

#Preview("Dark, largest text") {
    let container = PreviewData.container
    let saved = try! container.mainContext.fetch(FetchDescriptor<SavedRecipe>()).first!
    return NavigationStack { PasteMyVersionView(saved: saved) {} }
        .modelContainer(container)
        .environment(AssistantProvider())
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility5)
}
