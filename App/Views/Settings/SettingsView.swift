import SwiftUI
import SwiftData
import RecipeKit

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]
    @State private var prefs = UserPreferences()
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Diet") { DietEditor(prefs: $prefs).padding(.vertical, Theme.Spacing.xxs) }
                Section {
                    AvoidEditor(prefs: $prefs).padding(.vertical, Theme.Spacing.xxs)
                } header: {
                    Text("Avoid")
                } footer: {
                    Text("Ingredient flags are based on a limited list; check labels if you have allergies.")
                }
                Section("Ingredients you dislike") { DislikesEditor(prefs: $prefs).padding(.vertical, Theme.Spacing.xxs) }
                Section("Heat") { SpiceEditor(prefs: $prefs).padding(.vertical, Theme.Spacing.xxs) }
                Section("Cuisines you cook") { CuisineEditor(prefs: $prefs).padding(.vertical, Theme.Spacing.xxs) }
                Section("Weeknight cooking time") { WeeknightEditor(prefs: $prefs).padding(.vertical, Theme.Spacing.xxs) }
                Section("Household") { HouseholdEditor(prefs: $prefs) }
                SyncStatusSection()
                AssistantSettingsSection()
                PhotoStorageSection()
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                } footer: {
                    Text("Nothing leaves this iPhone except through your own iCloud account.")
                }
            }
            .listRowBackground(Color.mise.surface)
            .miseScreenBackground()
            .navigationTitle("Settings")
            .onAppear {
                guard !loaded else { return }
                prefs = profiles.first?.prefs ?? UserPreferences()
                loaded = true
            }
            .onChange(of: prefs) { _, newValue in
                guard loaded else { return }
                context.profile().prefs = newValue
                try? context.save()
            }
        }
    }
}

#Preview("Light") {
    SettingsView()
        .modelContainer(PreviewData.container)
        .environment(AssistantProvider())
        .environment(CloudSync(container: PreviewData.container, mode: .local(reason: nil)))
}

#Preview("Dark") {
    SettingsView()
        .modelContainer(PreviewData.container)
        .environment(AssistantProvider())
        .environment(CloudSync(container: PreviewData.container, mode: .local(reason: nil)))
        .preferredColorScheme(.dark)
}
