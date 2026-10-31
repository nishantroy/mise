import SwiftUI
import RecipeKit

/// Full-screen cook mode: the prep list first, then one step per page with "For this step"
/// ingredients and tap-to-start timers. Keeps the screen awake while open.
struct CookModeView: View {
    /// The recipe as shown on the detail screen, already scaled to the chosen servings.
    let recipe: Recipe
    /// "Done" on the last page: leads into "I made this".
    var onFinish: () -> Void
    var onClose: () -> Void

    @Environment(AssistantProvider.self) private var provider
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = 0
    @State private var forward = true
    @State private var plan: PrepPlan
    @State private var checked: Set<String> = []
    @State private var timers: CookTimerStore
    @State private var confirmExit = false
    @State private var exitFinishes = false
    @State private var previousIdleSetting = false
    private let links: StepIngredientLinker.Links
    private let stepTimers: [[CookTimerSpec]]

    init(recipe: Recipe, onFinish: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.recipe = recipe
        self.onFinish = onFinish
        self.onClose = onClose
        links = StepIngredientLinker().links(for: recipe)
        stepTimers = CookTimers.timers(for: recipe)
        // Ingredient IDs don't change with scaling, so a plan cached for any servings fits.
        let cached = PrepPlanCache.plan(for: recipe, usesModel: true) ?? PrepPlanCache.plan(for: recipe, usesModel: false)
        _plan = State(initialValue: cached ?? PrepPlanner().plan(for: recipe))
        _timers = State(initialValue: CookTimerStore(recipeTitle: recipe.title))
    }

    private var lastPage: Int { recipe.steps.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !timers.timers.isEmpty { timerBar }
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
        .onAppear {
            previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = previousIdleSetting
            timers.cancelAll()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { timers.checkExpired() }
        }
        .task { await refinePlan() }
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
                    Text(page == 0 ? "Mise en place" : "Step \(page) of \(recipe.steps.count)")
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
                if let servings = recipe.servings {
                    Text("For \(servings) \(servings == 1 ? "serving" : "servings"). Tick things off as you go.")
                        .font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                }
            }
            ForEach(plan.groups) { group in
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
                    Text(item.text(in: recipe))
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
                Text(recipe.steps[index])
                    .font(.title2)
                    .foregroundStyle(Color.mise.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Step \(index + 1). \(recipe.steps[index])")
                    .accessibilityIdentifier("cook.stepText")
            }
            if !stepTimers[index].isEmpty {
                FlowLayout(spacing: Theme.Spacing.xs) {
                    ForEach(stepTimers[index]) { spec in timerChip(spec) }
                }
            }
            let ids = links.forStep(index)
            if !ids.isEmpty {
                SectionCard(title: "For this step") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        ForEach(ids, id: \.self) { id in
                            if let ing = recipe.ingredient(id: id) { ingredientRow(ing) }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("cook.forThisStep")
            }
        }
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

    private func timerChip(_ spec: CookTimerSpec) -> some View {
        let running = timers.running(for: spec)
        return Button {
            if let running { timers.cancel(running.id) } else { timers.start(spec) }
        } label: {
            HStack(spacing: Theme.Spacing.xxs) {
                Image(systemName: running == nil ? "timer" : "stop.fill").font(Theme.Fonts.meta)
                if let running {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(CookTimers.clock(running.remaining(at: context.date))).monospacedDigit()
                    }
                } else {
                    Text(spec.label)
                }
            }
            .font(.headline)
            .padding(.horizontal, Theme.Spacing.m)
            .frame(minHeight: Theme.Size.minTap)
            .foregroundStyle(running == nil ? Color.mise.accent : Color.mise.onAccent)
            .background(running == nil ? Color.mise.surfaceSunken : Color.mise.accent, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(running == nil ? "Start \(spec.label) timer" : "Stop \(spec.label) timer")
        .accessibilityIdentifier("cook.timer.\(spec.position)")
    }

    // MARK: Timers

    private var timerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(timers.timers) { timer in
                    HStack(spacing: Theme.Spacing.xxs) {
                        Button { go(to: timer.step + 1) } label: {
                            HStack(spacing: Theme.Spacing.xxs) {
                                Image(systemName: timer.finished ? "bell.fill" : "timer")
                                Text("Step \(timer.step + 1)")
                                if timer.finished {
                                    Text("Done")
                                } else {
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        Text(CookTimers.clock(timer.remaining(at: context.date))).monospacedDigit()
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
            Button { timers.banner = nil } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "bell.fill").foregroundStyle(Color.mise.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Timer done").font(.headline).foregroundStyle(Color.mise.ink)
                        Text(done.title).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "xmark").foregroundStyle(Color.mise.inkSecondary).accessibilityHidden(true)
                }
                .padding(Theme.Spacing.m)
                .background(Color.mise.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Color.mise.accent, lineWidth: 2))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Spacing.gutter)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel("Timer done: \(done.title). Dismiss.")
            .accessibilityIdentifier("cook.banner")
            .task(id: done.id) {
                try? await Task.sleep(for: .seconds(10))
                if timers.banner?.id == done.id { withAnimation { timers.banner = nil } }
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

    private func requestExit(finishing: Bool) {
        if timers.hasRunning {
            exitFinishes = finishing
            confirmExit = true
        } else {
            leave(finishing: finishing)
        }
    }

    private func leave(finishing: Bool) {
        timers.cancelAll()
        if finishing { onFinish() } else { onClose() }
    }

    /// Computed when cook mode opens and cached per recipe revision. With the model on, its plan
    /// replaces the rules' one only if nothing has been ticked yet, so the list never shifts
    /// under the cook's finger.
    private func refinePlan() async {
        let usesModel = provider.usesModel
        if let cached = PrepPlanCache.plan(for: recipe, usesModel: usesModel) {
            if checked.isEmpty { plan = cached }
            return
        }
        guard usesModel else {
            PrepPlanCache.store(plan, for: recipe, usesModel: false)
            return
        }
        let assistant = provider.assistant
        let refined = (try? await assistant.planPrep(recipe: recipe)) ?? plan
        PrepPlanCache.store(refined, for: recipe, usesModel: true)
        if checked.isEmpty { withAnimation { plan = refined } }
    }
}

#Preview("Light") {
    CookModeView(recipe: PreviewData.recipe, onFinish: {}, onClose: {})
        .environment(AssistantProvider())
}

#Preview("Dark, largest text") {
    CookModeView(recipe: PreviewData.recipe, onFinish: {}, onClose: {})
        .environment(AssistantProvider())
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility5)
}
