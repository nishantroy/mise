import SwiftUI

/// Settings → iCloud: whether recipes, pantry, preferences, the cooking log and photos sync.
struct SyncStatusSection: View {
    @Environment(CloudSync.self) private var sync

    var body: some View {
        Section {
            Label {
                Text(sync.summary)
            } icon: {
                Image(systemName: sync.isOn ? "checkmark.icloud" : "icloud.slash")
                    .foregroundStyle(sync.isOn ? Color.mise.accent : Color.mise.inkSecondary)
            }
            .accessibilityIdentifier("settings.syncStatus")
            if sync.isOn, let last = sync.lastSync {
                LabeledContent("Last synced", value: last.formatted(.relative(presentation: .named)))
            }
            if sync.isOn, let error = sync.lastError {
                Text(error).font(.footnote).foregroundStyle(Color.mise.inkSecondary)
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text("Recipes, pantry, preferences, the cooking log and photos sync through your iCloud account. Cook-mode progress and links waiting to import stay on this iPhone.")
        }
        .onAppear { sync.refreshAccount() }
    }
}
