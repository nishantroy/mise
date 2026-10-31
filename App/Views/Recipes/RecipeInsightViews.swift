import SwiftUI
import RecipeKit

/// The cuisine on the detail screen. Tapping opens a menu to pick a different cuisine or clear
/// it; with no cuisine it reads "Add cuisine". Guessed and page cuisines look the same.
struct CuisineMenu: View {
    let cuisine: String?
    var onPick: (String) -> Void
    var onClear: () -> Void

    var body: some View {
        Menu {
            Section("Cuisine") {
                ForEach(UserPreferences.cuisineChoices, id: \.self) { choice in
                    Button {
                        onPick(choice)
                    } label: {
                        if choice == cuisine { Label(choice, systemImage: "checkmark") } else { Text(choice) }
                    }
                }
            }
            if cuisine != nil {
                Button("Clear cuisine", systemImage: "xmark", role: .destructive, action: onClear)
            }
        } label: {
            HStack(spacing: Theme.Spacing.xxs) {
                Text(cuisine ?? "Add cuisine")
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .foregroundStyle(Color.mise.inkSecondary)
            .frame(minHeight: Theme.Size.minTap)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(cuisine.map { "Cuisine: \($0)" } ?? "Add cuisine")
        .accessibilityHint("Change or clear the cuisine")
        .accessibilityIdentifier("detail.cuisine")
    }
}

/// The realistic-time line under the detail metadata, with the reason on demand, plus the
/// weeknight hint.
struct TimeInsightView: View {
    let recipe: Recipe
    /// Nil when there's no profile yet; then no weeknight hint.
    let prefs: UserPreferences?
    var isRechecking = false

    @State private var showReason = false

    var body: some View {
        let line = RecipeFormat.realisticTime(recipe)
        let longerThanWeeknight = prefs.map(recipe.exceedsWeeknightTime) ?? false
        if isRechecking || line != nil || longerThanWeeknight {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                if isRechecking {
                    HStack(spacing: Theme.Spacing.xs) {
                        ProgressView()
                        Text("Re-checking time and cuisine…")
                    }
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Color.mise.inkSecondary)
                    .accessibilityIdentifier("detail.rechecking")
                } else if let line, let estimate = recipe.timeEstimate {
                    Button {
                        withAnimation { showReason.toggle() }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                            Image(systemName: "clock")
                            Text(line).multilineTextAlignment(.leading)
                            Image(systemName: showReason ? "chevron.up" : "info.circle")
                                .imageScale(.small)
                        }
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Color.mise.ink)
                        .frame(minHeight: Theme.Size.minTap, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(line)
                    .accessibilityHint(showReason ? "Hides why" : "Shows why")
                    .accessibilityIdentifier("detail.timeEstimate")
                    if showReason {
                        Text(estimate.reason)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Color.mise.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("detail.timeReason")
                    }
                }
                if longerThanWeeknight && !isRechecking {
                    Label("Longer than your weeknight time", systemImage: "moon")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Color.mise.inkSecondary)
                        .accessibilityIdentifier("detail.weeknightHint")
                }
            }
        }
    }
}

#Preview("Light") {
    let recipe = Recipe(title: "Chow Mein", totalMinutes: 15, cuisine: "Chinese", cuisineIsGuess: true,
                        timeEstimate: TimeEstimate(totalMinutes: 30, activeMinutes: 20, passiveMinutes: 11,
                                                   reason: "About 15 min to prep 15 ingredients, 5 min of cooking and 11 min marinating.",
                                                   source: .rules, passiveLabel: "marinating"))
    VStack(alignment: .leading) {
        CuisineMenu(cuisine: "Chinese", onPick: { _ in }, onClear: {})
        TimeInsightView(recipe: recipe, prefs: UserPreferences(weeknightMinutes: 20))
    }
    .padding(Theme.Spacing.gutter)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.mise.background)
}

#Preview("Dark") {
    let recipe = Recipe(title: "Kung Pao Chicken",
                        timeEstimate: TimeEstimate(totalMinutes: 65, activeMinutes: 34, passiveMinutes: 30,
                                                   reason: "About 22 min to prep 22 ingredients, 12 min of cooking and 30 min marinating.",
                                                   source: .rules, passiveLabel: "marinating"))
    TimeInsightView(recipe: recipe, prefs: UserPreferences(weeknightMinutes: 30))
        .padding(Theme.Spacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.mise.background)
        .preferredColorScheme(.dark)
}
