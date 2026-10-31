import SwiftUI
import RecipeKit

/// Preference editors shared by onboarding (custom pages) and Settings (inside a Form).

struct DietEditor: View {
    @Binding var prefs: UserPreferences

    var body: some View {
        ChipGroup(items: Diet.allCases, title: \.label, isSelected: { prefs.diet == $0 },
                  toggle: { prefs.diet = $0 }, identifier: { "diet.\($0.rawValue)" })
    }
}

struct AvoidEditor: View {
    @Binding var prefs: UserPreferences

    var body: some View {
        ChipGroup(items: AvoidTag.allCases, title: \.label, isSelected: { prefs.avoid.contains($0) },
                  toggle: { tag in
                      if prefs.avoid.contains(tag) { prefs.avoid.remove(tag) } else { prefs.avoid.insert(tag) }
                  },
                  identifier: { "avoid.\($0.rawValue)" })
    }
}

struct DislikesEditor: View {
    @Binding var prefs: UserPreferences
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.xs) {
                TextField("e.g. cilantro, olives", text: $draft)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(add)
                    .padding(.horizontal, Theme.Spacing.s)
                    .frame(minHeight: Theme.Size.minTap)
                    .background(Color.mise.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .accessibilityIdentifier("prefs.dislikeField")
                Button("Add", action: add)
                    .buttonStyle(.miseSecondary)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("prefs.addDislike")
            }
            if !prefs.dislikes.isEmpty {
                FlowLayout {
                    ForEach(prefs.dislikes, id: \.self) { item in
                        RemovableChip(title: item) { prefs.dislikes.removeAll { $0 == item } }
                    }
                }
            }
        }
    }

    private func add() {
        let items = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        for item in items where !prefs.dislikes.contains(item) { prefs.dislikes.append(item) }
        draft = ""
    }
}

struct SpiceEditor: View {
    @Binding var prefs: UserPreferences

    var body: some View {
        ChipGroup(items: Array(UserPreferences.spiceLabels.indices), title: { UserPreferences.spiceLabels[$0] },
                  isSelected: { prefs.spiceLevel == $0 }, toggle: { prefs.spiceLevel = $0 },
                  identifier: { "spice.\($0)" })
    }
}

struct CuisineEditor: View {
    @Binding var prefs: UserPreferences

    var body: some View {
        ChipGroup(items: UserPreferences.cuisineChoices, title: { $0 }, isSelected: { prefs.cuisines.contains($0) },
                  toggle: { c in
                      if prefs.cuisines.contains(c) { prefs.cuisines.removeAll { $0 == c } } else { prefs.cuisines.append(c) }
                  },
                  identifier: { "cuisine.\($0)" })
    }
}

struct WeeknightEditor: View {
    @Binding var prefs: UserPreferences
    static let options: [Int] = [15, 20, 30, 45, 60, 0]  // 0 = no limit

    var body: some View {
        ChipGroup(items: Self.options, title: { $0 == 0 ? "No limit" : "\($0) min" },
                  isSelected: { ($0 == 0 ? nil : $0) == prefs.weeknightMinutes },
                  toggle: { prefs.weeknightMinutes = $0 == 0 ? nil : $0 },
                  identifier: { "weeknight.\($0)" })
    }
}

struct HouseholdEditor: View {
    @Binding var prefs: UserPreferences

    var body: some View {
        Stepper(value: $prefs.servings, in: 1...12) {
            HStack {
                Text("Household size").foregroundStyle(Color.mise.ink)
                Spacer()
                Text("\(prefs.servings)")
                    .foregroundStyle(Color.mise.inkSecondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("prefs.servingsValue")
            }
        }
        .accessibilityIdentifier("prefs.servings")
    }
}

/// A labelled block on an onboarding page.
struct QuestionBlock<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title).font(.headline).foregroundStyle(Color.mise.ink).accessibilityAddTraits(.isHeader)
            content
            if let footnote {
                Text(footnote).font(Theme.Fonts.caption).foregroundStyle(Color.mise.inkSecondary)
            }
        }
    }
}
