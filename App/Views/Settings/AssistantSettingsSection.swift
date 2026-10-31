import SwiftUI

/// Which assistant is active, and the "use rules only" toggle.
struct AssistantSettingsSection: View {
    @Environment(AssistantProvider.self) private var provider

    var body: some View {
        @Bindable var provider = provider
        Section {
            LabeledContent("Active", value: provider.assistant.displayName)
                .accessibilityIdentifier("settings.activeAssistant")
            Toggle("Use built-in rules only", isOn: $provider.forceRules)
                .accessibilityIdentifier("settings.forceRules")
        } header: {
            Text("Assistant")
        }
    }
}
