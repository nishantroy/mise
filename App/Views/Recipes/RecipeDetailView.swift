import SwiftUI
import SwiftData
import RecipeKit

struct RecipeDetailView: View {
    @Bindable var saved: SavedRecipe

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AssistantProvider.self) private var provider
    @Query private var profiles: [UserProfile]
    @State private var servings: Int?
    @State private var showingCheck = false
    @State private var showingAdjust = false
    /// "Change recipe": describe changes in words without logging a cook.
    @State private var showingChange = false
    @State private var showingCook = false
    /// Cook mode ended with "Done", so "I made this" opens once it has closed.
    @State private var cookFinished = false
    /// Swaps made while cooking, offered (unticked) in "I made this".
    @State private var finishedSwaps: [CookSwap] = []
    /// A cooking session that can be resumed ("Resume cooking (step 7)").
    @State private var session: CookSession?
    /// The session cook mode opens with; nil starts fresh.
    @State private var resuming: CookSession?
    @State private var showingMyVersion = false
    @State private var confirmReset = false
    @State private var confirmDelete = false
    @State private var rechecking = false
    /// A step being reworded from its context menu.
    @State private var editingStep: StepEditTarget?
    /// "Share recipe" with a photo: the "Include my photo" sheet.
    @State private var sharingPhoto: SharePhoto?
    /// Chosen in that sheet; the share sheet opens once it has closed.
    @State private var shareAfterDismiss: Bool?
    @State private var shareError: String?
    /// "Find a substitute" (tap or long-press an ingredient): the swap options sheet.
    @State private var substituting: Ingredient?
    /// "Leave it out" from the context menu: straight to "Just this time" / "Update the recipe".
    @State private var leaveOutChoice: SubstituteChoice?
    /// The last "Update the recipe" swap, for Undo, and the confirmation line.
    @State private var lastSwap: AppliedRecipeSwap?
    @State private var toast: String?

    private var recipe: Recipe { saved.recipe }
    private var displayed: Recipe {
        guard let servings else { return recipe }
        return recipe.scaled(to: servings)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                let photoURL = saved.displayPhotoURL(in: .shared)
                if recipe.imageURL != nil || photoURL != nil {
                    RecipeImage(url: recipe.imageURL, photoURL: photoURL)
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
                titleBlock
                if recipe.servings != nil { servingsCard }
                if let session, session.isSwapsOnly {
                    PlannedSwapsCard(swaps: session.swaps, onRemove: removePlannedSwap)
                }
                ingredientsCard
                stepsCard
                // Below the recipe it changes; the bottom bar stays "Start cooking" / "I made this".
                Button { showingChange = true } label: {
                    Label("Change recipe", systemImage: "pencil.line")
                }
                .buttonStyle(.miseSecondaryWide)
                .accessibilityHint("Describe changes in your own words, without logging a cook")
                .accessibilityIdentifier("detail.changeRecipe")
                if !recipe.notes.isEmpty { notesCard }
                if !saved.cookLog.isEmpty { CookedSection(saved: saved) }
                historyCard
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.m)
        }
        .miseScreenBackground()
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Spacing.s) {
                if let toast {
                    SwapToast(message: toast, onUndo: lastSwap.map { applied in { undoRecipeSwap(applied) } })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // Side by side; stacked when large text doesn't fit.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.s) { bottomActions }
                    VStack(spacing: Theme.Spacing.xs) { bottomActions }
                }
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.s)
            .background(Color.mise.background)
        }
        // The confirmation goes away by itself after a few seconds (and with it, Undo).
        .task(id: toast) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            withAnimation {
                toast = nil
                lastSwap = nil
            }
        }
        .sheet(item: $substituting) { ingredient in
            FindSubstituteSheet(ingredient: ingredient, recipe: displayed, cookInProgress: cookInProgress) { choice, decision in
                substituting = nil
                decide(choice, decision)
            }
            .presentationDetents([.medium, .large])
        }
        .substituteDecision($leaveOutChoice, cookInProgress: cookInProgress) { choice, decision in decide(choice, decision) }
        .fullScreenCover(isPresented: $showingCook, onDismiss: {
            loadSession()
            // "Done" in cook mode leads into "I made this".
            if cookFinished {
                cookFinished = false
                showingAdjust = true
            }
        }) {
            CookModeView(recipe: displayed, recipeID: saved.id, fingerprint: PrepPlanner.fingerprint(recipe), resume: resuming,
                         onFinish: { swaps in
                             finishedSwaps = swaps
                             cookFinished = true
                             showingCook = false
                         }, onClose: { showingCook = false })
        }
        .onAppear { loadSession() }
        // After an edit (or the launch sweep) the estimate is the rules'; let the model refine it.
        .task(id: saved.recipe.timeEstimate?.basis) {
            await EstimateRefresh.refine(saved, provider: provider, context: context)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Share recipe", systemImage: "square.and.arrow.up") { startSharing() }
                    .accessibilityIdentifier("detail.share")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Change recipe", systemImage: "pencil.line") { showingChange = true }
                        .accessibilityIdentifier("detail.menu.changeRecipe")
                    Button("Share recipe", systemImage: "square.and.arrow.up") { startSharing() }
                        .accessibilityIdentifier("detail.menu.share")
                    Button("Paste my version", systemImage: "doc.on.clipboard") { showingMyVersion = true }
                    if let session, !session.isSwapsOnly {
                        Button("I made this", systemImage: "checkmark.circle") {
                            finishedSwaps = session.swaps
                            showingAdjust = true
                        }
                    }
                    Button("Check ingredients", systemImage: "checklist") { showingCheck = true }
                    Button("Re-check time and cuisine", systemImage: "clock.arrow.circlepath") { recheck() }
                        .disabled(rechecking)
                    if let url = recipe.sourceURL {
                        Link(destination: url) { Label("Open original page", systemImage: "safari") }
                    }
                    Button("Reset to original", systemImage: "arrow.uturn.backward") { confirmReset = true }
                    Button("Delete recipe", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("detail.menu")
            }
        }
        .confirmationDialog("Reset to the imported version?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset to original", role: .destructive) {
                saved.resetToOriginal()
                servings = nil
                try? context.save()
            }
        } message: {
            Text("Your changes stay in the history.")
        }
        .confirmationDialog("Delete this recipe?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                CookLogging.deletePhotos(of: saved)
                context.delete(saved)
                try? context.save()
                dismiss()
            }
        }
        .sheet(item: $sharingPhoto, onDismiss: {
            if let includePhoto = shareAfterDismiss {
                shareAfterDismiss = nil
                share(includePhoto: includePhoto)
            }
        }) { photo in
            NavigationStack {
                ShareRecipeSheet(title: recipe.title, photoURL: photo.url, photoIsShared: saved.latestPhoto == nil) { includePhoto in
                    shareAfterDismiss = includePhoto
                    sharingPhoto = nil
                }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Couldn't share this recipe", isPresented: Binding(get: { shareError != nil }, set: { if !$0 { shareError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareError ?? "")
        }
        .sheet(isPresented: $showingCheck) {
            NavigationStack {
                IngredientCheckView(recipe: recipe, existing: saved) { _ in showingCheck = false }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingCheck = false } }
                    }
            }
        }
        .sheet(isPresented: $showingAdjust, onDismiss: { finishedSwaps = [] }) {
            NavigationStack {
                AdjustRecipeView(saved: saved, sessionSwaps: finishedSwaps, servingsCooked: servings ?? recipe.servings) {
                    // Logged as cooked: the session is over (its alarms are left alone).
                    CookSessionStore.clear(saved.id)
                    session = nil
                }
            }
        }
        .sheet(isPresented: $showingChange) {
            NavigationStack {
                AdjustRecipeView(saved: saved, mode: .change)
            }
        }
        .sheet(isPresented: $showingMyVersion) {
            NavigationStack {
                PasteMyVersionView(saved: saved) { showingMyVersion = false }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingMyVersion = false } }
                    }
            }
        }
    }

    // MARK: Sections

    /// "Start cooking" (cook mode, at the servings chosen above) and "I made this"; or, with a
    /// session to pick up, "Resume cooking (step 7)" and "Start over".
    /// A swaps-only session ("Swap ready for your next cook") keeps "Start cooking" / "I made this".
    @ViewBuilder
    private var bottomActions: some View {
        if let session, !session.isSwapsOnly {
            Button { resume(session) } label: {
                Label(session.page == 0 ? "Resume cooking" : "Resume cooking (step \(session.page))", systemImage: "frying.pan")
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.misePrimary)
            .accessibilityIdentifier("detail.resumeCooking")
            Button { startOver(session) } label: {
                Text("Start over").fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.miseSecondaryTall)
            .accessibilityIdentifier("detail.startOver")
        } else {
            startButtons
        }
    }

    @ViewBuilder
    private var startButtons: some View {
        Button { startCooking() } label: {
            Label("Start cooking", systemImage: "frying.pan").fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.misePrimary)
        .disabled(recipe.steps.isEmpty)
        .accessibilityIdentifier("detail.startCooking")
        Button {
            // Cooked without cook mode: swaps set up "just this time" are offered as in cook mode.
            finishedSwaps = session?.swaps ?? []
            showingAdjust = true
        } label: {
            Text("I made this").fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.miseSecondaryTall)
        .accessibilityIdentifier("detail.madeThis")
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(recipe.title).serifTitle(Theme.Fonts.header).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("detail.title")
            HStack(spacing: Theme.Spacing.s) {
                if let time = RecipeFormat.time(recipe) {
                    Text(time).accessibilityLabel(recipe.displayTime?.isEstimate == true ? "About \(time.dropFirst()), estimated" : time)
                        .accessibilityIdentifier("detail.time")
                }
                CuisineMenu(cuisine: RecipeFormat.cuisine(recipe), onPick: setCuisine, onClear: { setCuisine(nil) })
                if saved.timesCooked > 0 { Text("Cooked \(saved.timesCooked)×") }
                if let rating = saved.rating, rating != 0 {
                    Image(systemName: rating > 0 ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                        .accessibilityLabel(rating > 0 ? "Liked" : "Disliked")
                }
            }
            .font(Theme.Fonts.meta)
            .foregroundStyle(Color.mise.inkSecondary)
            TimeInsightView(recipe: recipe, prefs: profiles.first?.prefs, isRechecking: rechecking)
            if let host = recipe.sourceURL?.host() {
                Text(host.replacingOccurrences(of: "www.", with: ""))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color.mise.inkSecondary)
            }
        }
    }

    // MARK: Actions

    private func loadSession() {
        session = CookSessionStore.resumable(for: saved.id, recipe: saved.recipe)
    }

    /// "Start cooking": fresh, or with the swaps set up "just this time" (at the servings shown now).
    private func startCooking() {
        if let session, session.isSwapsOnly {
            let ready = session.rescaled(to: displayed.servings, base: recipe)
            CookSessionStore.save(ready)
            self.session = ready
            resuming = ready
        } else {
            resuming = nil
        }
        showingCook = true
    }

    // MARK: Find a substitute

    /// A cook that has actually started (not just swaps set up ahead).
    private var cookInProgress: Bool { session.map { !$0.isSwapsOnly } ?? false }

    /// "Next cook: ginger and garlic" under an ingredient with a swap in the session.
    private func sessionSwapLine(for ingredient: Ingredient) -> String? {
        guard let session, let swap = session.swap(for: ingredient.id) else { return nil }
        let lead = session.isSwapsOnly ? "Next cook" : "This cook"
        return swap.isSkip ? "\(lead): leaving it out" : "\(lead): \(swap.newName)"
    }

    @ViewBuilder
    private func ingredientMenu(_ ingredient: Ingredient) -> some View {
        Button("Find a substitute", systemImage: "arrow.triangle.swap") { substituting = ingredient }
        Button("Leave it out", systemImage: "minus.circle") { leaveOut(ingredient) }
        if let swap = session?.swap(for: ingredient.id) {
            Button(cookInProgress ? "Undo swap for this cook" : "Remove swap for next cook", systemImage: "arrow.uturn.backward") {
                removePlannedSwap(swap)
            }
        }
    }

    private func leaveOut(_ ingredient: Ingredient) {
        leaveOutChoice = SubstituteChoice(ingredient: ingredient, suggestion: nil, consequence: SkipConsequence.text(for: ingredient))
    }

    private func decide(_ choice: SubstituteChoice, _ decision: SubstituteDecision) {
        switch decision {
        case .justThisTime: swapForNextCook(choice)
        case .updateRecipe: swapInRecipe(choice)
        }
    }

    /// Marks the ingredient missing in the pantry (as cook mode does); returns the key and what it said before.
    private func markMissing(_ ingredient: Ingredient) -> (key: String, before: String?) {
        let key = IngredientCatalog.shared.pantryKey(for: ingredient)
        let before = context.pantryStatus(key: key)?.rawValue
        context.setPantry(key: key, displayName: ingredient.name, status: .missing)
        return (key, before)
    }

    private func restorePantry(key: String?, before: String?, name: String) {
        guard let key else { return }
        if let status = before.flatMap(PantryStatus.init(rawValue:)) {
            context.setPantry(key: key, displayName: name, status: status)
        } else {
            context.removePantry(key: key)
        }
    }

    /// "Just this time": the swap goes into the cook session (a new one for the next cook, or the
    /// one in progress), the same mechanism as cook mode's "Out of something?".
    private func swapForNextCook(_ choice: SubstituteChoice) {
        let base = recipe
        var current = session ?? CookSession.planned(recipeID: saved.id, base: base, servings: displayed.servings)
        if current.isSwapsOnly { current = current.rescaled(to: displayed.servings, base: base) }
        let previous = current.swap(for: choice.ingredient.id)
        guard var (next, swap) = current.settingSwap(of: choice.ingredient.id, suggestion: choice.suggestion,
                                                    consequence: choice.consequence, base: base) else { return }
        if let previous {
            swap.pantryKey = previous.pantryKey
            swap.pantryBefore = previous.pantryBefore
            context.setPantry(key: previous.pantryKey ?? IngredientCatalog.shared.pantryKey(for: choice.ingredient),
                              displayName: choice.ingredient.name, status: .missing)
        } else {
            let marked = markMissing(choice.ingredient)
            swap.pantryKey = marked.key
            swap.pantryBefore = marked.before
        }
        try? context.save()
        next.swaps[next.swaps.count - 1] = swap
        // A ticked prep item that now needs something different is unticked (as in cook mode).
        if !swap.isSkip, let plan = next.plan {
            let covering = Set(plan.itemIDs(covering: choice.ingredient.id))
            next.checkedPrep.removeAll { covering.contains($0) }
        }
        CookSessionStore.save(next)
        withAnimation {
            session = next
            lastSwap = nil
            toast = next.isSwapsOnly ? "Ready for your next cook: \(swap.label)" : "Added to your cook: \(swap.label)"
        }
    }

    /// Removes a swap set up "just this time" (or undoes one in a cook in progress) and puts the
    /// pantry back.
    private func removePlannedSwap(_ swap: CookSwap) {
        guard let session else { return }
        let next = session.removingSwap(swap.id)
        restorePantry(key: swap.pantryKey, before: swap.pantryBefore, name: swap.original.name)
        try? context.save()
        if next.hasProgress {
            CookSessionStore.save(next)
            withAnimation { self.session = next }
        } else {
            CookSessionStore.clear(saved.id)
            withAnimation { self.session = nil }
        }
    }

    /// "Update the recipe": the same edits as keeping a cook-mode swap (amounts at the recipe's own
    /// servings, steps renamed / rescaled / collapsed), saved as a revision "Swapped X for Y".
    private func swapInRecipe(_ choice: SubstituteChoice) {
        let before = recipe
        let edits = RecipeSwap.edits(for: choice.ingredient.id, suggestion: choice.suggestion, in: before)
        guard !edits.isEmpty else { return }
        let summary = RecipeSwap.summary(of: edits, in: before)
        let sessionBefore = session
        saved.apply(edits, summary: summary)
        let marked = markMissing(choice.ingredient)
        try? context.save()
        // Swaps set up for the next cook carry over to the edited recipe (other ingredients only).
        if let old = sessionBefore, old.isSwapsOnly {
            var carried = CookSession.planned(recipeID: saved.id, base: saved.recipe, servings: old.servings)
            for swap in old.swaps where swap.original.id != choice.ingredient.id {
                guard var (next, moved) = carried.settingSwap(of: swap.original.id, suggestion: swap.suggestion,
                                                             consequence: swap.consequence, base: saved.recipe) else { continue }
                moved.id = swap.id
                moved.pantryKey = swap.pantryKey
                moved.pantryBefore = swap.pantryBefore
                next.swaps[next.swaps.count - 1] = moved
                carried = next
            }
            if carried.hasProgress { CookSessionStore.save(carried) } else { CookSessionStore.clear(saved.id) }
        }
        loadSession()
        withAnimation {
            lastSwap = AppliedRecipeSwap(revisionID: saved.revisions.last?.id, before: before, session: sessionBefore,
                                         pantryKey: marked.key, pantryBefore: marked.before, name: choice.ingredient.name)
            toast = summary
        }
    }

    /// Undo for "Update the recipe": only while that revision is still the latest.
    private func undoRecipeSwap(_ applied: AppliedRecipeSwap) {
        if let id = applied.revisionID, saved.revisions.last?.id == id {
            saved.recipe = applied.before
            var revisions = saved.revisions
            revisions.removeLast()
            saved.revisions = revisions
            restorePantry(key: applied.pantryKey, before: applied.pantryBefore, name: applied.name)
            try? context.save()
            if let old = applied.session { CookSessionStore.save(old) }
            loadSession()
        }
        withAnimation {
            lastSwap = nil
            toast = nil
        }
    }

    /// Opens cook mode where the session left off, at its servings.
    private func resume(_ session: CookSession) {
        servings = session.servings == recipe.servings ? nil : session.servings
        resuming = session
        showingCook = true
    }

    /// Drops the session (cancelling its alarms) and starts cooking from the prep list.
    private func startOver(_ session: CookSession) {
        CookSessionStore.discard(session)
        self.session = nil
        resuming = nil
        showingCook = true
    }

    /// With a photo, ask whether to include it first; otherwise straight to the share sheet.
    private func startSharing() {
        if let url = RecipeSharing.photoURL(for: saved) {
            sharingPhoto = SharePhoto(url: url)
        } else {
            share(includePhoto: false)
        }
    }

    private func share(includePhoto: Bool) {
        do {
            let file = try RecipeSharing.makeFile(for: saved, includePhoto: includePhoto)
            RecipeSharing.present(file: file, recipe: saved.recipe,
                                  photoURL: includePhoto ? RecipeSharing.photoURL(for: saved) : nil)
        } catch let failure as SharedRecipeFile.Failure {
            shareError = failure.message
        } catch {
            shareError = error.localizedDescription
        }
    }

    private func setCuisine(_ cuisine: String?) {
        saved.setCuisine(cuisine)
        try? context.save()
    }

    /// Re-runs the cuisine guess and time estimate (fills in recipes saved before they existed).
    private func recheck() {
        rechecking = true
        let current = saved.recipe
        let assistant = provider.assistant
        Task {
            let enriched = await RecipeInsights.enrich(current, using: assistant)
            saved.updateInsights(cuisineGuess: enriched.cuisineIsGuess ? enriched.cuisine : nil,
                                 estimate: enriched.timeEstimate)
            try? context.save()
            rechecking = false
        }
    }

    private var servingsCard: some View {
        MiseCard {
            let current = servings ?? recipe.servings ?? 1
            Stepper(value: Binding(get: { current }, set: { servings = $0 == recipe.servings ? nil : $0 }), in: 1...50) {
                HStack {
                    Text("Servings").foregroundStyle(Color.mise.ink)
                    Spacer()
                    Text("\(current)").monospacedDigit().foregroundStyle(Color.mise.ink)
                        .accessibilityIdentifier("detail.servingsValue")
                }
            }
            .accessibilityIdentifier("detail.servings")
        }
    }

    private var ingredientsCard: some View {
        SectionCard(title: "Ingredients") {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach(displayed.ingredients) { ing in
                    // Tap: the swap options for this ingredient. Long-press: the same, or leave it out.
                    Button { substituting = ing } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                            Text(RecipeFormat.amount(ing) ?? "")
                                .monospacedDigit()
                                .foregroundStyle(Color.mise.ink)
                                .frame(minWidth: 72, alignment: .leading)
                                .fontWeight(.semibold)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(RecipeFormat.capitalised(ing.name)).foregroundStyle(Color.mise.ink)
                                if let note = ing.note {
                                    Text(note).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                                }
                                if let line = sessionSwapLine(for: ing) {
                                    Label(line, systemImage: "arrow.triangle.swap")
                                        .font(Theme.Fonts.meta)
                                        .foregroundStyle(Color.mise.herb)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: Theme.Size.minTap - Theme.Spacing.s)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { ingredientMenu(ing) }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Find a substitute")
                    .accessibilityAction(named: "Find a substitute") { substituting = ing }
                    .accessibilityAction(named: "Leave it out") { leaveOut(ing) }
                    .accessibilityIdentifier("detail.ingredient")
                }
                // Low-key hint so the tap is discoverable without a button on every row.
                Label("Tap an ingredient to find a substitute", systemImage: "arrow.triangle.swap")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color.mise.inkSecondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private var stepsCard: some View {
        SectionCard(title: "Steps") {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        Text("\(index + 1)")
                            .font(Theme.Fonts.badge)
                            .foregroundStyle(Color.mise.onAccent)
                            .frame(minWidth: Theme.Size.stepBadge, minHeight: Theme.Size.stepBadge)
                            .background(Color.mise.accent, in: Circle())
                            .accessibilityLabel("Step \(index + 1)")
                        Text(step).foregroundStyle(Color.mise.ink).fixedSize(horizontal: false, vertical: true)
                    }
                    .contentShape(Rectangle())
                    // Long-press to reword a step; saved as a revision like any other edit.
                    .contextMenu {
                        Button("Edit step", systemImage: "pencil") {
                            editingStep = StepEditTarget(stepIndex: index, original: step, initial: step)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: "Edit step") {
                        editingStep = StepEditTarget(stepIndex: index, original: step, initial: step)
                    }
                    .accessibilityIdentifier("detail.step")
                }
            }
        }
        .sheet(item: $editingStep) { target in
            StepEditSheet(title: "Edit step \(target.stepIndex + 1)", original: target.original, initial: target.initial) { text in
                guard text != target.original, saved.recipe.steps.indices.contains(target.stepIndex) else { return }
                saved.apply([.updateStep(index: target.stepIndex, text: text)], summary: "Edited step \(target.stepIndex + 1)")
                try? context.save()
            }
        }
    }

    private var notesCard: some View {
        SectionCard(title: "Notes") {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(Array(recipe.notes.enumerated()), id: \.offset) { _, note in
                    Label(note, systemImage: "text.quote")
                        .foregroundStyle(Color.mise.ink)
                        .accessibilityIdentifier("detail.note")
                }
            }
        }
    }

    private var historyCard: some View {
        SectionCard(title: "History") {
            let revisions = saved.revisions
            if revisions.isEmpty {
                Text("No changes yet.").foregroundStyle(Color.mise.inkSecondary)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    ForEach(revisions.reversed()) { revision in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(revision.date, format: .dateTime.day().month().year().hour().minute())
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Color.mise.inkSecondary)
                            Text(revision.summary).foregroundStyle(Color.mise.ink)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("detail.revision")
                    }
                }
            }
        }
    }
}

#Preview("Light") {
    let container = PreviewData.container
    let saved = try! container.mainContext.fetch(FetchDescriptor<SavedRecipe>()).first!
    return NavigationStack { RecipeDetailView(saved: saved) }
        .modelContainer(container)
        .environment(AssistantProvider())
}

#Preview("Dark") {
    let container = PreviewData.container
    let saved = try! container.mainContext.fetch(FetchDescriptor<SavedRecipe>()).first!
    return NavigationStack { RecipeDetailView(saved: saved) }
        .modelContainer(container)
        .environment(AssistantProvider())
        .preferredColorScheme(.dark)
}
