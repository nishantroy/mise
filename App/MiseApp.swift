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
            CookPhotoStore.shared.deleteAll()
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
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            if profiles.first?.onboardingDone == true {
                MainTabView()
            } else {
                OnboardingFlow()
            }
        }
        // A `.mise` file opened from Messages, Mail, Files or AirDrop. Here rather than on the
        // tabs so a cold launch (or one into onboarding) doesn't drop it: it's queued, and the
        // tabs show it when they appear.
        .onOpenURL { url in
            guard url.isFileURL else { return }
            let showNow = profiles.first?.onboardingDone == true
            do {
                router.receiveRecipeFile(try IncomingRecipeFiles.readOpened(url), showNow: showNow)
            } catch {
                // Unreadable or too big: the preview explains it isn't a recipe it can open.
                if showNow, router.activeImport == nil { router.activeImport = ImportRequest(sharedRecipeData: Data()) }
            }
        }
    }
}

struct MainTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AssistantProvider.self) private var provider
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context

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
            // Once per launch: estimates computed from older steps or rules → the rules' for now.
            EstimateRefresh.sweep(context)
            // Pick up links and text shared from other apps. Each stays in the App Group queue
            // until its sheet closes, so nothing is lost if the app is killed mid-import.
            router.onSharedImportFinished = { PendingImports.remove($0) }
            router.enqueue(PendingImports.pending())
        }
        .sheet(item: $router.activeImport, onDismiss: { router.importSheetDismissed() }) { request in
            NavigationStack {
                if let data = request.sharedRecipeData {
                    SharedRecipePreview(data: data) { saved in
                        router.activeImport = nil
                        if let saved { router.open(recipeID: saved.id) }
                    }
                } else if let text = request.sharedText {
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
