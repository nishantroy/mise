import SwiftUI
import SwiftData
import RecipeKit

@main
struct MiseApp: App {
    @State private var container = Persistence.makeContainer()
    @State private var assistantProvider = AssistantProvider()
    @State private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(assistantProvider)
                .environment(router)
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
    @Environment(AppRouter.self) private var router
    @Environment(AssistantProvider.self) private var provider
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Recipes", systemImage: "book", value: AppTab.recipes) { RecipeListView() }
            Tab("Pantry", systemImage: "cabinet", value: AppTab.pantry) { PantryView() }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { provider.refresh() }
        }
        .sheet(item: $router.activeImport, onDismiss: { router.importSheetDismissed() }) { request in
            NavigationStack {
                ImportView(initialURL: request.url) { saved in
                    router.activeImport = nil
                    router.open(recipeID: saved.id)
                }
            }
        }
    }
}
