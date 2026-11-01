import SwiftUI
import RecipeKit

/// Full-screen cook mode: the prep list first, then one step per page with "For this step"
/// ingredients and tap-to-start timers. Keeps the screen awake while open.
///
/// "Missing an ingredient?" swaps or skips an ingredient for this cook only (`CookSwap`): the working
/// recipe's amounts, step text, prep list and "For this step" follow, and "I made this" offers
/// each swap unticked. The session (page, ticks, swaps, timers) is saved as it changes, so
/// closing cook mode or the app being killed can be resumed from the recipe.
struct CookModeView: View {
    /// The recipe as shown on the detail screen, already scaled to the chosen servings.
    let recipe: Recipe
    let recipeID: UUID
    /// `PrepPlanner.fingerprint` of the saved (unscaled) recipe, stored with the session.
    let fingerprint: String
    /// A session to pick up ("Resume cooking"), or nil to start fresh.
    let resume: CookSession?
    /// "Done" on the last page: leads into "I made this" with the session's swaps.
    var onFinish: ([CookSwap]) -> Void
    var onClose: () -> Void

    @Environment(AssistantProvider.self) private var provider
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var page: Int
    @State private var forward = true
    @State private var plan: PrepPlan
    @State private var checked: Set<String>
    @State private var timers: CookTimerStore
    @State private var confirmExit = false
    @State private var confirmClose = false
    @State private var exitFinishes = false
    @State private var previousIdleSetting = false
    @State private var swaps: [CookSwap]
    /// `recipe` with the swaps applied: what every page shows.
    @State private var working: Recipe
    /// Per step, "Swapped: sherry for Shaoxing wine" lines.
    @State private var swapNotes: [Int: [String]]
    @State private var links: StepIngredientLinker.Links
    @State private var stepTimers: [[CookTimerSpec]]
    @State private var showingOutOf = false
    @State private var restored = false
    /// Done or closed: stop saving the session.
    @State private var ended = false
    private let startedAt: Date

    init(recipe: Recipe, recipeID: UUID = UUID(), fingerprint: String? = nil, resume: CookSession? = nil,
         onFinish: @escaping ([CookSwap]) -> Void, onClose: @escaping () -> Void) {
        self.recipe = recipe
        self.recipeID = recipeID
        self.fingerprint = fingerprint ?? PrepPlanner.fingerprint(recipe)
        self.resume = resume
        self.onFinish = onFinish
        self.onClose = onClose
        let swaps = resume?.swaps ?? []
        let replay = CookSwapApplier.replay(swaps, on: recipe)
        _swaps = State(initialValue: swaps)
        _working = State(initialValue: replay.recipe)
        _swapNotes = State(initialValue: replay.notes)
        _links = State(initialValue: StepIngredientLinker().links(for: replay.recipe))
        _stepTimers = State(initialValue: CookTimers.timers(for: replay.recipe))
        // Ingredient IDs don't change with scaling, so a plan cached for any servings fits.
        let cached = PrepPlanCache.plan(for: recipe, usesModel: true) ?? PrepPlanCache.plan(for: recipe, usesModel: false)
        _plan = State(initialValue: resume?.plan ?? cached ?? PrepPlanner().plan(for: recipe))
        _checked = State(initialValue: Set(resume?.checkedPrep ?? []))
        _page = State(initialValue: min(max(resume?.page ?? 0, 0), recipe.steps.count))
        _timers = State(initialValue: CookTimerStore(recipeTitle: recipe.title))
        startedAt = resume?.startedAt ?? .now
    }

    private var lastPage: Int { working.steps.count }

    /// The prep list with swapped ingredients replaced and fully skipped items hidden.
    private var shownPlan: PrepPlan {
        var map: [UUID: [UUID]] = [:]
        for swap in swaps where !swap.isSkip { map[swap.original.id] = swap.replacements.map(\.id) }
        return plan.substituting(map).visible(in: working)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !stripTimers.isEmpty { timerBar }
            ZStack {
                pageView(page)
                    .id(page)
                    .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .simultaneousGesture(swipe)
            navigationBar
        }
        .background(Color.mise.background.ignoresSafeArea())
        .overlay(alignment: .top) { banner }
        .confirmationDialog(exitFinishes ? "Finish cooking?" : "Stop cooking?", isPresented: $confirmExit, titleVisibility: .visible) {
            Button(exitFinishes ? "Finish" : "Stop cooking", role: .destructive) { leave(finishing: exitFinishes) }
                .accessibilityIdentifier("cook.confirmExit")
            Button("Keep cooking", role: .cancel) {}
        } message: {
            Text("Running timers will be cancelled.")
        }
        .confirmationDialog("Leave cook mode?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Leave, timers keep running") { close(stoppingTimers: false) }
                .accessibilityIdentifier("cook.leaveKeepTimers")
            Button("Stop timers and leave", role: .destructive) { close(stoppingTimers: true) }
                .accessibilityIdentifier("cook.leaveStopTimers")
            Button("Keep cooking", role: .cancel) {}
        } message: {
            Text("You can pick up where you left off from the recipe.")
        }
        .sheet(isPresented: $showingOutOf) {
            OutOfSomethingView(recipe: working, stepIndex: page > 0 ? page - 1 : nil, links: links, swaps: swaps,
                               onChoose: { ingredient, suggestion, consequence in
                                   applySwap(ingredient, suggestion: suggestion, consequence: consequence)
                                   showingOutOf = false
                               },
                               onUndo: undo)
        }
        .onAppear {
            previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            restoreTimers()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = previousIdleSetting
            // Alarms keep running for a resumed session; only the in-app waits stop.
            timers.suspend()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { timers.checkExpired() }
            if phase != .active { persist() }
        }
        .onChange(of: page) { persist() }
        .onChange(of: checked) { persist() }
        .onChange(of: swaps) { persist() }
        .onChange(of: timers.timers) { persist() }
        .task { await refinePlan() }
        .task { await timers.observeAlarms() }
    }

    // MARK: Chrome

    private var header: some View {
        VStack(spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.s) {
                Button { requestExit(finishing: false) } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(minWidth: Theme.Size.minTap, minHeight: Theme.Size.minTap)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(Color.mise.ink)
                .accessibilityLabel("Close cook mode")
                .accessibilityIdentifier("cook.close")
                VStack(alignment: .leading, spacing: 0) {
                    Text(recipe.title).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary).lineLimit(1)
                    Text(page == 0 ? "Mise en place" : "Step \(page) of \(working.steps.count)")
                        .font(.headline).foregroundStyle(Color.mise.ink)
                        .accessibilityIdentifier("cook.pageTitle")
                }
                Spacer(minLength: 0)
            }
            ProgressView(value: Double(page), total: Double(max(lastPage, 1)))
                .tint(Color.mise.accent)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.bottom, Theme.Spacing.xs)
    }

    /// "Missing an ingredient?": a plain text link under the step's ingredients (and on the prep
    /// page), always spelled out; an icon alone didn't say what it does.
    private var outOfButton: some View {
        Button { showingOutOf = true } label: {
            HStack(spacing: Theme.Spacing.xxs) {
                Text("Missing an ingredient?")
                Image(systemName: "chevron.right").font(Theme.Fonts.caption.weight(.semibold))
            }
            .font(Theme.Fonts.meta.weight(.semibold))
            .foregroundStyle(Color.mise.accent)
            .frame(minHeight: Theme.Size.minTap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Missing an ingredient?")
        .accessibilityHint("Swap or skip it for this cook")
        .accessibilityIdentifier("cook.outOf")
    }

    private var navigationBar: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button { go(to: page - 1) } label: { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.miseSecondary)
                .disabled(page == 0)
                .accessibilityIdentifier("cook.back")
            if page == lastPage {
                Button { requestExit(finishing: true) } label: { Label("Done", systemImage: "checkmark") }
                    .buttonStyle(.misePrimary)
                    .accessibilityIdentifier("cook.done")
            } else {
                Button { go(to: page + 1) } label: { Text(page == 0 ? "Start step 1" : "Next") }
                    .buttonStyle(.misePrimary)
                    .accessibilityIdentifier("cook.next")
            }
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.vertical, Theme.Spacing.s)
        .background(Color.mise.background)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24).onEnded { value in
            let dx = value.translation.width, dy = value.translation.height
            guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
            go(to: dx < 0 ? page + 1 : page - 1)
        }
    }

    // MARK: Pages

    @ViewBuilder
    private func pageView(_ index: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if index == 0 { prepPage } else { stepPage(index - 1) }
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.m)
        }
        .scrollContentBackground(.hidden)
    }

    private var prepPage: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text("Mise en place").serifTitle(Theme.Fonts.header).accessibilityAddTraits(.isHeader)
                if let servings = working.servings {
                    Text("For \(servings) \(servings == 1 ? "serving" : "servings"). Tick things off as you go.")
                        .font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                }
                outOfButton
            }
            if !swaps.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    ForEach(swaps) { swap in swapNote(swap.label) }
                }
            }
            ForEach(shownPlan.groups) { group in
                SectionCard(title: group.kind.title) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        ForEach(group.items) { item in prepRow(item, kind: group.kind) }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("cook.prep.\(group.kind.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cook.prep")
    }

    private func prepRow(_ item: PrepItem, kind: PrepGroupKind) -> some View {
        let done = checked.contains(item.id)
        return Button {
            if done { checked.remove(item.id) } else { checked.insert(item.id) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? Color.mise.herb : Color.mise.inkSecondary)
                    .font(.title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(item.text(in: working))
                        .font(.title3)
                        .foregroundStyle(done ? Color.mise.inkSecondary : Color.mise.ink)
                        .strikethrough(done, color: Color.mise.inkSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    let meta = [item.minutes.map { "\($0) min" }, kind == .startEarly ? item.step.map { "Step \($0 + 1)" } : nil]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !meta.isEmpty {
                        Text(meta).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Spacing.xxs)
            .frame(minHeight: Theme.Size.minTap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(done ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("cook.prep.item")
    }

    private func stepPage(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text("\(index + 1)")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.mise.onAccent)
                    .frame(minWidth: Theme.Size.minTap, minHeight: Theme.Size.minTap)
                    .background(Color.mise.accent, in: Circle())
                    .accessibilityHidden(true)
                Text(working.steps[index])
                    .font(.title2)
                    .foregroundStyle(Color.mise.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Step \(index + 1). \(working.steps[index])")
                    .accessibilityIdentifier("cook.stepText")
            }
            if let notes = swapNotes[index], !notes.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    ForEach(notes, id: \.self) { swapNote($0) }
                }
            }
            if !stepTimers[index].isEmpty {
                // One row per timer: its name, then its controls.
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    ForEach(stepTimers[index]) { spec in timerRow(spec) }
                }
            }
            let ids = links.forStep(index)
            if !ids.isEmpty {
                SectionCard(title: "For this step") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        ForEach(ids, id: \.self) { id in
                            if let ing = working.ingredient(id: id) { ingredientRow(ing) }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("cook.forThisStep")
            }
            outOfButton
        }
    }

    /// "Swapped: mirin for sherry" under a step (and on the prep page).
    private func swapNote(_ text: String) -> some View {
        Label(text, systemImage: "arrow.triangle.2.circlepath")
            .font(Theme.Fonts.meta.weight(.semibold))
            .foregroundStyle(Color.mise.caution)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("cook.swapNote")
    }

    private func ingredientRow(_ ing: Ingredient) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Text(RecipeFormat.amount(ing) ?? "")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.mise.ink)
                .frame(minWidth: 80, alignment: .leading)
            Text(RecipeFormat.capitalised(ing.name))
                .font(.title3)
                .foregroundStyle(Color.mise.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cook.ingredient")
    }

    /// A timer's name ("Brown the beef") beside its controls, or above them when they don't fit
    /// (long names, large Dynamic Type). The countdown never wraps.
    private func timerRow(_ spec: CookTimerSpec) -> some View {
        let name = Text(CookTimerStore.RunningTimer.isFallback(spec.title, step: spec.step) ? "Timer" : spec.title)
            .font(Theme.Fonts.meta.weight(.semibold))
            .foregroundStyle(Color.mise.ink)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.s) {
                name.lineLimit(1)
                Spacer(minLength: Theme.Spacing.xs)
                timerControls(spec, compact: false)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                name.fixedSize(horizontal: false, vertical: true)
                timerControls(spec, compact: false)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                name.fixedSize(horizontal: false, vertical: true)
                timerControls(spec, compact: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// Tap starts the timer (a range's high end). While running: tap stops it, and −1 min /
    /// +1 min sit either side ("−1" / "+1" when space is short).
    @ViewBuilder
    private func timerControls(_ spec: CookTimerSpec, compact: Bool) -> some View {
        if let running = timers.running(for: spec) {
            HStack(spacing: Theme.Spacing.xs) {
                adjustButton(compact ? "−1" : "−1 min", label: "Take a minute off \(spec.label) timer",
                             id: "cook.timer.\(spec.position).minus") {
                    timers.adjust(running.id, by: -60)
                }
                .disabled(!CookTimerAdjust.canShorten(remaining: running.remaining(at: .now)))
                Button { timers.cancel(running.id) } label: {
                    chipLabel(icon: "stop.fill", running: true) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            countdown(running.remaining(at: context.date))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop \(spec.label) timer")
                .accessibilityIdentifier("cook.timer.\(spec.position)")
                adjustButton(compact ? "+1" : "+1 min", label: "Add a minute to \(spec.label) timer",
                             id: "cook.timer.\(spec.position).plus") {
                    timers.adjust(running.id, by: 60)
                }
            }
            .fixedSize()
        } else {
            Button { timers.start(spec) } label: {
                chipLabel(icon: "timer", running: false) { Text(spec.label).lineLimit(1) }
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Start \(spec.label) timer")
            .accessibilityIdentifier("cook.timer.\(spec.position)")
        }
    }

    /// "2:58" in fixed-width digits, on one line.
    private func countdown(_ remaining: TimeInterval) -> some View {
        Text(CookTimers.clock(remaining))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    private func chipLabel<Content: View>(icon: String, running: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Image(systemName: icon).font(Theme.Fonts.meta)
            content()
        }
        .font(.headline)
        .padding(.horizontal, Theme.Spacing.s)
        .frame(minHeight: Theme.Size.minTap)
        .foregroundStyle(running ? Color.mise.onAccent : Color.mise.accent)
        .background(running ? Color.mise.accent : Color.mise.surfaceSunken, in: Capsule())
        .contentShape(Capsule())
    }

    private func adjustButton(_ title: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Fonts.meta.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.s)
                .frame(minWidth: Theme.Size.minTap, minHeight: Theme.Size.minTap)
                .foregroundStyle(Color.mise.accent)
                .background(Color.mise.surfaceSunken, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    // MARK: Timers

    /// Timers from other steps, plus finished ones: the current step's running timers already
    /// have their own rows on the page.
    private var stripTimers: [CookTimerStore.RunningTimer] {
        timers.timers.filter { $0.finished || $0.step + 1 != page }
    }

    private var timerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(stripTimers) { timer in
                    HStack(spacing: Theme.Spacing.xxs) {
                        Button { go(to: timer.step + 1) } label: {
                            HStack(spacing: Theme.Spacing.xxs) {
                                Image(systemName: timer.finished ? "bell.fill" : "timer")
                                // Names are at most four words; the strip scrolls sideways.
                                Text(timer.shortName).lineLimit(1).fixedSize()
                                if timer.finished {
                                    Text("Done").lineLimit(1).fixedSize()
                                } else {
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        countdown(timer.remaining(at: context.date))
                                    }
                                }
                            }
                            .frame(minHeight: Theme.Size.minTap)
                        }
                        .accessibilityLabel(timer.finished ? "\(timer.title), done" : "\(timer.title), running")
                        Button { timers.cancel(timer.id) } label: {
                            Image(systemName: "xmark")
                                .font(Theme.Fonts.caption)
                                .frame(minWidth: Theme.Size.minTap - 12, minHeight: Theme.Size.minTap)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(timer.finished ? "Dismiss \(timer.title)" : "Cancel \(timer.title)")
                    }
                    .font(Theme.Fonts.meta.weight(.semibold))
                    .padding(.leading, Theme.Spacing.s)
                    .foregroundStyle(timer.finished ? Color.mise.onAccent : Color.mise.ink)
                    .background(timer.finished ? Color.mise.herb : Color.mise.surfaceSunken, in: Capsule())
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            .padding(.horizontal, Theme.Spacing.gutter)
        }
        .padding(.bottom, Theme.Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cook.timerBar")
    }

    @ViewBuilder
    private var banner: some View {
        if let done = timers.banner {
            let sounding = timers.bannerIsSounding
            Button { withAnimation { timers.dismissBanner() } } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "bell.fill").foregroundStyle(Color.mise.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Timer done").font(.headline).foregroundStyle(Color.mise.ink)
                        Text(done.title).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                    }
                    Spacer(minLength: 0)
                    if sounding {
                        Text("Stop").font(Theme.Fonts.button).foregroundStyle(Color.mise.accent).accessibilityHidden(true)
                    } else {
                        Image(systemName: "xmark").foregroundStyle(Color.mise.inkSecondary).accessibilityHidden(true)
                    }
                }
                .padding(Theme.Spacing.m)
                .background(Color.mise.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Color.mise.accent, lineWidth: 2))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Spacing.gutter)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel(sounding ? "Timer done: \(done.title). Stop." : "Timer done: \(done.title). Dismiss.")
            .accessibilityIdentifier("cook.banner")
            .task(id: "\(done.id)-\(sounding)") {
                // Stays up while the alarm or tone is sounding, so there's always a way to stop it.
                guard !sounding else { return }
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                if timers.banner?.id == done.id, !timers.bannerIsSounding { withAnimation { timers.dismissBanner() } }
            }
        }
    }

    // MARK: Actions

    private func go(to target: Int) {
        let clamped = min(max(target, 0), lastPage)
        guard clamped != page else { return }
        forward = clamped > page
        withAnimation(.easeInOut(duration: 0.25)) { page = clamped }
    }

    /// Done asks only when a timer is running (finishing stops them). Close keeps the session;
    /// with timers running it asks whether they should keep going.
    private func requestExit(finishing: Bool) {
        if finishing {
            if timers.hasRunning {
                exitFinishes = true
                confirmExit = true
            } else {
                leave(finishing: true)
            }
        } else if timers.hasRunning {
            confirmClose = true
        } else {
            close(stoppingTimers: false)
        }
    }

    /// Finished: timers stop and the session is cleared.
    private func leave(finishing: Bool) {
        timers.cancelAll()
        ended = true
        CookSessionStore.clear(recipeID)
        if finishing { onFinish(swaps) } else { onClose() }
    }

    /// Closed with ✕: the session is kept for "Resume cooking".
    private func close(stoppingTimers: Bool) {
        if stoppingTimers { timers.cancelAll() } else { timers.suspend() }
        persist()
        ended = true
        onClose()
    }

    // MARK: Session

    private func persist() {
        guard !ended, restored else { return }
        let session = CookSession(recipeID: recipeID, fingerprint: fingerprint, servings: recipe.servings, page: page,
                                  checkedPrep: Array(checked).sorted(), plan: plan, swaps: swaps,
                                  timers: timers.sessionTimers, startedAt: startedAt, updatedAt: .now)
        CookSessionStore.save(session)
    }

    /// A resumed session's timers, matched with the alarms that still exist (stopped ones are
    /// dropped; ones whose time has passed are done).
    private func restoreTimers() {
        guard !restored else { return }
        if let resume, !resume.timers.isEmpty {
            let reconciled = CookTimerReconciler.reconcile(resume.timers, alarms: CookSessionStore.alarmStates(), now: .now)
            timers.restore(reconciled)
        }
        restored = true
        persist()
    }

    // MARK: Swaps

    /// Applies a swap (nil suggestion: skip) to this cook: working recipe, prep ticks (an item that
    /// now needs a different ingredient is unticked), pantry ("missing"), then asks the model for
    /// tidier step wording if it can answer quickly.
    private func applySwap(_ ingredient: Ingredient, suggestion: SwapSuggestion?, consequence: String?) {
        var swap = CookSwap.make(original: ingredient, suggestion: suggestion, consequence: consequence)
        let key = IngredientCatalog.shared.pantryKey(for: ingredient)
        swap.pantryKey = key
        swap.pantryBefore = context.pantryStatus(key: key)?.rawValue
        context.setPantry(key: key, displayName: ingredient.name, status: .missing)
        try? context.save()
        if !swap.isSkip {
            for id in plan.itemIDs(covering: ingredient.id) { checked.remove(id) }
        }
        withAnimation { swaps.append(swap) }
        recompute()
        if provider.usesModel, !swap.isSkip { Task { await reword(swap) } }
    }

    private func undo(_ swap: CookSwap) {
        withAnimation { swaps.removeAll { $0.id == swap.id } }
        recompute()
        if let key = swap.pantryKey {
            if let before = swap.pantryBefore.flatMap(PantryStatus.init(rawValue:)) {
                context.setPantry(key: key, displayName: swap.original.name, status: before)
            } else {
                context.removePantry(key: key)
            }
            try? context.save()
        }
    }

    private func recompute() {
        let replay = CookSwapApplier.replay(swaps, on: recipe)
        working = replay.recipe
        swapNotes = replay.notes
        links = StepIngredientLinker().links(for: replay.recipe)
        stepTimers = CookTimers.timers(for: replay.recipe)
    }

    /// The validated single-step rewrite, only when the model answers within a few seconds
    /// (otherwise the rules' text stays). Only for a swap that leaves a step naming the new
    /// ingredient twice, and not when the amount in the text was rescaled.
    private func reword(_ swap: CookSwap) async {
        guard let index = swaps.firstIndex(where: { $0.id == swap.id }),
              CookSwapApplier.amountRatio(swap.original, swap.replacements) == nil else { return }
        let before = CookSwapApplier.replay(Array(swaps[..<index]), on: recipe).recipe
        let edit = RecipeEdit.replaceIngredient(id: swap.original.id, with: swap.replacements, reason: nil)
        guard !StepRewrites.requests(recipe: before, edits: [edit]).isEmpty else { return }
        let assistant = provider.assistant
        let proposals = await withTaskGroup(of: [StepRewriteProposal]?.self) { group -> [StepRewriteProposal] in
            group.addTask { try? await assistant.proposeStepRewrites(recipe: before, edits: [edit], feedback: "") }
            group.addTask {
                try? await Task.sleep(for: .seconds(6))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
        guard !proposals.isEmpty, let current = swaps.firstIndex(where: { $0.id == swap.id }) else { return }
        var plain = swaps[current]
        plain.reworded = []
        let rulesText = CookSwapApplier.replay(Array(swaps[..<current]) + [plain], on: recipe).recipe.steps
        let patches = proposals.compactMap { p -> StepPatch? in
            guard rulesText.indices.contains(p.stepIndex) else { return nil }
            return StepPatch(stepIndex: p.stepIndex, from: rulesText[p.stepIndex], to: p.newText)
        }
        guard !patches.isEmpty else { return }
        swaps[current].reworded = patches
        recompute()
    }

    /// Computed when cook mode opens and cached per recipe revision. With the model on, its plan
    /// replaces the rules' one only if nothing has been ticked yet, so the list never shifts
    /// under the cook's finger.
    private func refinePlan() async {
        // A resumed session keeps the list it was ticking.
        guard resume?.plan == nil else { return }
        let usesModel = provider.usesModel
        if let cached = PrepPlanCache.plan(for: recipe, usesModel: usesModel) {
            if checked.isEmpty && swaps.isEmpty { plan = cached }
            return
        }
        guard usesModel else {
            PrepPlanCache.store(plan, for: recipe, usesModel: false)
            return
        }
        let assistant = provider.assistant
        let refined = (try? await assistant.planPrep(recipe: recipe)) ?? plan
        PrepPlanCache.store(refined, for: recipe, usesModel: true)
        if checked.isEmpty && swaps.isEmpty { withAnimation { plan = refined } }
    }
}

#Preview("Light") {
    CookModeView(recipe: PreviewData.recipe, onFinish: { _ in }, onClose: {})
        .environment(AssistantProvider())
        .modelContainer(PreviewData.container)
}

#Preview("Dark, largest text") {
    CookModeView(recipe: PreviewData.recipe, onFinish: { _ in }, onClose: {})
        .environment(AssistantProvider())
        .modelContainer(PreviewData.container)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility5)
}
