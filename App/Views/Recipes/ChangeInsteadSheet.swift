import SwiftUI
import RecipeKit

/// What a "Change the recipe" choice opens for: the proposal it replaces and the note behind it.
struct ChangeInsteadTarget: Identifiable {
    let id = UUID()
    let proposalIndex: Int
    let note: UnresolvedNote
}

/// "Change recipe": words nothing could turn into a change. Nothing is chosen until the cook
/// picks "Save as note" (a toggle) or "Change the recipe" (a step or an ingredient, by hand).
struct UnresolvedNoteRow: View {
    let note: UnresolvedNote
    @Binding var isOn: Bool
    let identifier: String
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("“\(note.said)”").foregroundStyle(Color.mise.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(isOn ? "Will be saved as a note." : "Couldn't turn this into a change. Save it as a note, or change a step or an ingredient yourself.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color.mise.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.s) { buttons }
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) { buttons }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var buttons: some View {
        Button {
            isOn.toggle()
        } label: {
            Label("Save as note", systemImage: isOn ? "checkmark.circle.fill" : "circle")
                .font(Theme.Fonts.meta)
                .frame(minHeight: Theme.Size.minTap)
        }
        .buttonStyle(.bordered)
        .tint(isOn ? Color.mise.accent : Color.mise.inkSecondary)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier + ".note")
        Button(action: onChange) {
            Label("Change the recipe", systemImage: "pencil")
                .font(Theme.Fonts.meta)
                .frame(minHeight: Theme.Size.minTap)
        }
        .buttonStyle(.bordered)
        .tint(Color.mise.accent)
        .accessibilityIdentifier(identifier + ".change")
    }
}

/// "Change the recipe" for words nothing could turn into a change: pick the step or the
/// ingredient it's about (the most likely one is pre-selected), then edit it by hand.
struct ChangeInsteadSheet: View {
    let note: UnresolvedNote
    let recipe: Recipe
    let onStep: (_ index: Int, _ text: String) -> Void
    let onIngredient: (RecipeEdit) -> Void

    enum Part: Hashable { case step, ingredient }

    @Environment(\.dismiss) private var dismiss
    @State private var part: Part
    @State private var step: Int?
    @State private var ingredient: UUID?
    @State private var editing = false

    init(note: UnresolvedNote, recipe: Recipe, onStep: @escaping (Int, String) -> Void, onIngredient: @escaping (RecipeEdit) -> Void) {
        self.note = note
        self.recipe = recipe
        self.onStep = onStep
        self.onIngredient = onIngredient
        let step = note.stepIndex.flatMap { recipe.steps.indices.contains($0) ? $0 : nil }
        let ingredient = note.ingredientID.flatMap { id in recipe.ingredients.contains { $0.id == id } ? id : nil }
        _step = State(initialValue: step)
        _ingredient = State(initialValue: ingredient)
        // A step when one is suggested (or nothing is), otherwise the ingredient.
        _part = State(initialValue: step == nil && ingredient != nil ? .ingredient : .step)
    }

    private var canContinue: Bool { part == .step ? step != nil : ingredient != nil }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("You said: “\(note.said)”")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Color.mise.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("What it's about", selection: $part) {
                        Text("A step").tag(Part.step)
                        Text("An ingredient").tag(Part.ingredient)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("changeInstead.part")
                }
                if part == .step {
                    Section("Which step is it about?") {
                        ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, text in
                            row(selected: step == index, suggested: note.stepIndex == index,
                                title: "Step \(index + 1)", detail: text, identifier: "changeInstead.step.\(index)") {
                                step = index
                            }
                        }
                    }
                } else {
                    Section("Which ingredient is it about?") {
                        ForEach(recipe.ingredients) { ing in
                            row(selected: ingredient == ing.id, suggested: note.ingredientID == ing.id,
                                title: ing.displayText, detail: nil, identifier: "changeInstead.ingredient.\(ing.id)") {
                                ingredient = ing.id
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .miseScreenBackground()
            .navigationTitle("Change the recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") { editing = true }
                        .disabled(!canContinue)
                        .accessibilityIdentifier("changeInstead.next")
                }
            }
            .navigationDestination(isPresented: $editing) { editor }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private var editor: some View {
        if part == .step, let step, recipe.steps.indices.contains(step) {
            StepEditForm(title: "Step \(step + 1)", original: recipe.steps[step], initial: recipe.steps[step],
                         context: "You said: “\(note.said)”") { text in
                if text != recipe.steps[step] { onStep(step, text) }
                dismiss()
            }
        } else if let id = ingredient, let ing = recipe.ingredient(id: id) {
            IngredientEditForm(ingredient: ing, said: note.said) { edit in
                onIngredient(edit)
                dismiss()
            }
        }
    }

    private func row(selected: Bool, suggested: Bool, title: String, detail: String?, identifier: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(title).foregroundStyle(Color.mise.ink)
                        if suggested {
                            Text("Suggested").font(Theme.Fonts.badge).foregroundStyle(Color.mise.accent)
                        }
                    }
                    if let detail {
                        Text(detail).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary).lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.mise.accent)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Theme.Size.minTap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}

/// One ingredient's line, edited as text ("4 cloves garlic", "chicken thighs"), or left out.
struct IngredientEditForm: View {
    let ingredient: Ingredient
    let said: String
    let onDone: (RecipeEdit) -> Void

    @State private var text: String

    init(ingredient: Ingredient, said: String, onDone: @escaping (RecipeEdit) -> Void) {
        self.ingredient = ingredient
        self.said = said
        self.onDone = onDone
        _text = State(initialValue: ingredient.displayText)
    }

    private var edit: RecipeEdit? { FeedbackParser(kind: .change).ingredientChange(ingredient, to: text) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("You said: “\(said)”").font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Amount and ingredient", text: $text)
                    .textInputAutocapitalization(.never)
                    .padding(Theme.Spacing.s)
                    .background(Color.mise.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .accessibilityIdentifier("ingredientEdit.text")
                Text("Change the amount (“4 cloves garlic”) or the ingredient (“chicken thighs”).")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color.mise.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Leave it out", systemImage: "minus.circle") {
                    onDone(.removeIngredient(id: ingredient.id))
                }
                .font(Theme.Fonts.meta)
                .tint(Color.mise.accent)
                .frame(minHeight: Theme.Size.minTap)
                .accessibilityIdentifier("ingredientEdit.remove")
            }
            .padding(Theme.Spacing.gutter)
        }
        .miseScreenBackground()
        .navigationTitle(ingredient.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { if let edit { onDone(edit) } }
                    .disabled(edit == nil)
                    .accessibilityIdentifier("ingredientEdit.done")
            }
        }
    }
}
