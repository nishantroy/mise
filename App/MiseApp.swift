import SwiftUI
import SwiftData
import RecipeKit

@main
struct MiseApp: App {
    @State private var container = Persistence.makeContainer()
    @State private var assistantProvider = AssistantProvider()
    @State private var router = AppRouter()

    init() {
        if LaunchOptions.resetData {
            PendingImports.clear()
            CookSessionStore.clearAll()
        }
        // UI tests: simulate the share extension having queued a URL.
        if let url = LaunchOptions.enqueueImport { PendingImports.append(url) }
        if let text = LaunchOptions.enqueueText { PendingImports.appendText(text) }
    }

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
            guard phase == .active else { return }
            provider.refresh()
            // Pick up links and text shared from other apps. Each stays in the App Group queue
            // until its sheet closes, so nothing is lost if the app is killed mid-import.
            router.onSharedImportFinished = { PendingImports.remove($0) }
            router.enqueue(PendingImports.pending())
        }
        .sheet(item: $router.activeImport, onDismiss: { router.importSheetDismissed() }) { request in
            NavigationStack {
                if let text = request.sharedText {
                    SharedTextView(text: text) { saved in
                        router.activeImport = nil
                        if let saved { router.open(recipeID: saved.id) }
                    }
                } else {
                    ImportView(initialURL: request.url) { saved in
                        router.activeImport = nil
                        router.open(recipeID: saved.id)
                    }
                }
            }
        }
    }
}
