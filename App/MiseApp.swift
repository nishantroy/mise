import SwiftUI
import SwiftData
import RecipeKit

@main
struct MiseApp: App {
    @State private var container = Persistence.makeContainer()
    @State private var assistantProvider = AssistantProvider()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(assistantProvider)
                .environment(\.recipeFetcher, Self.fetcher)
                .miseTheme()
        }
        .modelContainer(container)
    }

    static var fetcher: any RecipeFetching {
        if let pages = LaunchOptions.stubPages { return StubRecipeFetcher(pages: pages) }
        return RecipeFetcher()
    }
}

/// Onboarding until it's done, then the tabs.
struct RootView: View {
    @Query private var profiles: [UserProfile]

    var body: some View {
        if profiles.first?.onboardingDone == true {
            MainTabView()
        } else {
            OnboardingFlow()
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Recipes", systemImage: "book") { RecipeListView() }
            Tab("Pantry", systemImage: "cabinet") { PantryView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
    }
}
