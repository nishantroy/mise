import SwiftUI
import RecipeKit

/// A step being edited by hand: from a proposal (`proposalIndex`) or the recipe detail.
struct StepEditTarget: Identifiable {
    let id = UUID()
    var proposalIndex: Int?
    let stepIndex: Int
    /// The step as saved.
    let original: String
    /// What the editor starts with (a proposal's new text, or the saved step).
    let initial: String
}

/// A proposed change to one step: compact before/after with the changed words struck through
/// and highlighted, the feedback it came from, and a switch. Tapping the text opens an editor.
struct StepChangeRow: View {
    let rewrite: StepRewriteProposal
    @Binding var isOn: Bool
    var isAvailable = true
    let identifier: String
    let onEdit: () -> Void

    private var title: String {
        let n = rewrite.stepIndex + 1
        if rewrite.removesStep { return "Remove step \(n)" }
        return rewrite.fromFeedback ? "Change step \(n)" : "Reword step \(n)"
    }

    private var diff: StepTextDiff {
        StepTextDiff(old: rewrite.oldText, new: rewrite.newText).compact(context: 5)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(spacing: Theme.Spacing.xxs) {
                        Text(title).foregroundStyle(Color.mise.ink)
                        Image(systemName: "pencil").font(Theme.Fonts.caption).foregroundStyle(Color.mise.inkSecondary)
                            .accessibilityHidden(true)
                    }
                    if rewrite.removesStep {
                        Text(rewrite.oldText)
                            .font(Theme.Fonts.meta)
                            .strikethrough(true, color: Color.mise.inkSecondary)
                            .foregroundStyle(Color.mise.inkSecondary)
                            .lineLimit(3)
                    } else {
                        line("Was", Self.text(diff, changed: diff.removed, isOld: true))
                        line("Now", Self.text(diff, changed: diff.added, isOld: false))
                    }
                    if let reason = rewrite.reason {
                        Text("You said: “\(reason)”").font(Theme.Fonts.caption).foregroundStyle(Color.mise.inkSecondary)
                    }
                    if !isAvailable {
                        Text("Needs the change it rewords.").font(Theme.Fonts.caption).foregroundStyle(Color.mise.inkSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rewrite.removesStep ? "\(title): \(rewrite.oldText)"
                                : "\(title). Was: \(rewrite.oldText). Becomes: \(rewrite.newText)")
            .accessibilityHint("Edit the step's text")
            .accessibilityIdentifier(identifier + ".edit")

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(Color.mise.accent)
                .disabled(!isAvailable)
                .accessibilityIdentifier(identifier)
        }
    }

    private func line(_ label: String, _ text: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            Text(label).font(Theme.Fonts.badge).foregroundStyle(Color.mise.inkSecondary)
            Text(text).font(Theme.Fonts.meta)
        }
    }

    /// Unchanged words in grey; removed words struck through, added words highlighted.
    static func text(_ diff: StepTextDiff, changed: String, isOld: Bool) -> AttributedString {
        var prefix = AttributedString(diff.prefix)
        prefix.foregroundColor = Color.mise.inkSecondary
        var middle = AttributedString(changed)
        if isOld {
            middle.foregroundColor = Color.mise.inkSecondary
            middle.strikethroughStyle = .single
        } else {
            middle.foregroundColor = Color.mise.ink
            middle.backgroundColor = Color.mise.accent.opacity(Theme.tintFillOpacity * 1.5)
        }
        var suffix = AttributedString(diff.suffix)
        suffix.foregroundColor = Color.mise.inkSecondary
        return prefix + middle + suffix
    }
}

/// A plain text editor for one step: the escape hatch when neither the rules nor the model
/// wrote the change right.
struct StepEditSheet: View {
    let title: String
    let original: String
    let initial: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    init(title: String, original: String, initial: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.original = original
        self.initial = initial
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            StepEditForm(title: title, original: original, initial: initial) { text in
                onSave(text)
                dismiss()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The step editor's content and its Done button, for a sheet or a pushed screen.
struct StepEditForm: View {
    let title: String
    let original: String
    /// Shown above the editor ("You said: …").
    var context: String? = nil
    let onDone: (String) -> Void

    @State private var text: String

    init(title: String, original: String, initial: String, context: String? = nil, onDone: @escaping (String) -> Void) {
        self.title = title
        self.original = original
        self.context = context
        self.onDone = onDone
        _text = State(initialValue: initial)
    }

    private var cleaned: String { text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                if let context {
                    Text(context).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .padding(Theme.Spacing.xs)
                    .background(Color.mise.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .accessibilityLabel("Step text")
                    .accessibilityIdentifier("stepEdit.text")
                if cleaned != original {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("As saved").font(Theme.Fonts.badge).foregroundStyle(Color.mise.inkSecondary)
                        Text(original).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(Theme.Spacing.gutter)
        }
        .miseScreenBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { onDone(cleaned) }
                    .disabled(cleaned.isEmpty)
                    .accessibilityIdentifier("stepEdit.done")
            }
        }
    }
}
