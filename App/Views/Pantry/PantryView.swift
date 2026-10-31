import SwiftUI
import SwiftData
import RecipeKit

struct PantryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PantryEntry.displayName) private var entries: [PantryEntry]
    @State private var draft = ""
    @State private var draftStatus: PantryStatus = .have

    private var have: [PantryEntry] { entries.filter { $0.pantryStatus == .have } }
    private var missing: [PantryEntry] { entries.filter { $0.pantryStatus == .missing } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        TextField("Add an ingredient", text: $draft)
                            .submitLabel(.done)
                            .onSubmit(add)
                            .padding(.horizontal, Theme.Spacing.s)
                            .frame(minHeight: Theme.Size.minTap)
                            .background(Color.mise.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                            .accessibilityIdentifier("pantry.addField")
                        HStack {
                            Picker("Status", selection: $draftStatus) {
                                Text("Have").tag(PantryStatus.have)
                                Text("Don't have").tag(PantryStatus.missing)
                            }
                            .pickerStyle(.segmented)
                            Button("Add", action: add)
                                .buttonStyle(.miseSecondary)
                                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                                .accessibilityIdentifier("pantry.addButton")
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xxs)
                }
                .listRowBackground(Color.mise.surface)

                if entries.isEmpty {
                    EmptyState(systemImage: "cabinet", title: "Your pantry is empty",
                               message: "Add things you keep in stock. Mise also remembers your answers when it asks about an ingredient.")
                        .listRowBackground(Color.clear)
                }
                if !have.isEmpty {
                    Section {
                        ForEach(have) { row($0) }
                    } header: {
                        Text("Have").serifTitle(Theme.Fonts.sectionTitle).textCase(nil)
                    }
                    .listRowBackground(Color.mise.surface)
                }
                if !missing.isEmpty {
                    Section {
                        ForEach(missing) { row($0) }
                    } header: {
                        Text("Missing").serifTitle(Theme.Fonts.sectionTitle).textCase(nil)
                    }
                    .listRowBackground(Color.mise.surface)
                }
            }
            .listStyle(.insetGrouped)
            .miseScreenBackground()
            .navigationTitle("Pantry")
        }
    }

    private func row(_ entry: PantryEntry) -> some View {
        let has = entry.pantryStatus == .have
        return HStack(spacing: Theme.Spacing.s) {
            Image(systemName: has ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(has ? Color.mise.herb : Color.mise.caution)
                .accessibilityHidden(true)
            Text(entry.displayName.prefix(1).uppercased() + entry.displayName.dropFirst())
                .foregroundStyle(Color.mise.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(has ? "Have" : "Don't have")
        .accessibilityIdentifier("pantry.row.\(entry.key)")
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { context.delete(entry); try? context.save() }
        }
        .swipeActions(edge: .leading) {
            Button(has ? "Move to Missing" : "Move to Have") { toggle(entry) }
                .tint(has ? Color.mise.caution : Color.mise.herb)
        }
        .accessibilityActions {
            Button(has ? "Move to Missing" : "Move to Have") { toggle(entry) }
            Button("Delete") { context.delete(entry); try? context.save() }
        }
    }

    private func toggle(_ entry: PantryEntry) {
        entry.pantryStatus = entry.pantryStatus == .have ? .missing : .have
        entry.updatedAt = Date()
        try? context.save()
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let catalog = IngredientCatalog.shared
        if let entry = catalog.match(text) {
            context.setPantry(key: entry.id, displayName: entry.displayName, status: draftStatus)
        } else {
            context.setPantry(key: IngredientCatalog.normalisedName(text), displayName: text.lowercased(), status: draftStatus)
        }
        try? context.save()
        draft = ""
    }
}

#Preview("Light") {
    PantryView().modelContainer(PreviewData.container)
}

#Preview("Dark") {
    PantryView().modelContainer(PreviewData.container).preferredColorScheme(.dark)
}
