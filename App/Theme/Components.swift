import SwiftUI

// MARK: - Card

/// Surface card: 16pt continuous corners, 16pt padding, hairline border, soft shadow in light mode.
struct MiseCard<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.m
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.mise.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Color.mise.divider, lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .light ? 0.06 : 0), radius: 8, y: 2)
    }
}

/// Card with a title row, used for Ingredients, Steps, History.
struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        MiseCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text(title)
                    .serifTitle(Theme.Fonts.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                content
            }
        }
    }
}

// MARK: - Buttons

/// Full-width accent capsule, at least 50pt tall.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.button)
            .foregroundStyle(Color.mise.onAccent)
            .frame(maxWidth: .infinity, minHeight: Theme.Size.primaryButtonHeight)
            .padding(.horizontal, Theme.Spacing.m)
            .background(Color.mise.accent.opacity(isEnabled ? 1 : 0.4), in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Capsule())
    }
}

/// Accent label on a sunken capsule.
struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.button)
            .foregroundStyle(Color.mise.accent.opacity(isEnabled ? 1 : 0.5))
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: Theme.Size.minTap)
            .padding(.horizontal, Theme.Spacing.m)
            .background(Color.mise.surfaceSunken, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var misePrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var miseSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static var miseSecondaryWide: SecondaryButtonStyle { SecondaryButtonStyle(fullWidth: true) }
}

/// Convenience wrappers named in the design spec.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        }
        .buttonStyle(.misePrimary)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        }
        .buttonStyle(.miseSecondary)
    }
}

// MARK: - Chips

/// Selectable capsule chip: sunken at rest, accent when selected.
struct Chip: View {
    let title: String
    @Binding var isOn: Bool
    var systemImage: String?

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: Theme.Spacing.xxs) {
                if isOn { Image(systemName: "checkmark").font(Theme.Fonts.badge) }
                else if let systemImage { Image(systemName: systemImage).font(Theme.Fonts.caption) }
                Text(title).lineLimit(2).multilineTextAlignment(.leading)
            }
            .font(Theme.Fonts.meta)
            .padding(.horizontal, Theme.Spacing.s)
            .frame(minHeight: Theme.Size.minTap)
            .foregroundStyle(isOn ? Color.mise.onAccent : Color.mise.ink)
            .background(isOn ? Color.mise.accent : Color.mise.surfaceSunken, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "Selected" : "Not selected")
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }
}

/// Wrapping group of chips for a set of options.
struct ChipGroup<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    let isSelected: (Item) -> Bool
    let toggle: (Item) -> Void
    var identifier: (Item) -> String = { "\($0)" }

    var body: some View {
        FlowLayout(spacing: Theme.Spacing.xs) {
            ForEach(items, id: \.self) { item in
                Chip(title: title(item), isOn: Binding(get: { isSelected(item) }, set: { _ in toggle(item) }))
                    .accessibilityIdentifier(identifier(item))
            }
        }
    }
}

/// A removable chip for free-text lists (dislikes).
struct RemovableChip: View {
    let title: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Text(title).foregroundStyle(Color.mise.ink)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .frame(minWidth: Theme.Size.minTap, minHeight: Theme.Size.minTap)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.mise.inkSecondary)
            .accessibilityLabel("Remove \(title)")
        }
        .font(Theme.Fonts.meta)
        .padding(.leading, Theme.Spacing.s)
        .background(Color.mise.surfaceSunken, in: Capsule())
    }
}

// MARK: - Badge

struct Badge: View {
    let title: String
    var systemImage: String?
    var tone: Color = Color.mise.herb

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title)
        }
        .font(Theme.Fonts.badge)
        .foregroundStyle(tone)
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.xxs)
        .background(tone.opacity(Theme.tintFillOpacity), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Review card

enum ReviewTone {
    case conflict, caution, herb

    var color: Color {
        switch self {
        case .conflict: Color.mise.conflict
        case .caution: Color.mise.caution
        case .herb: Color.mise.herb
        }
    }
}

/// Card with a 4pt leading colour bar, a symbol and a title.
struct ReviewCard<Content: View>: View {
    let tone: ReviewTone
    let systemImage: String
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        MiseCard(padding: 0) {
            HStack(spacing: 0) {
                Rectangle().fill(tone.color).frame(width: Theme.Size.reviewBar).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                        Image(systemName: systemImage).foregroundStyle(tone.color).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.headline).foregroundStyle(Color.mise.ink)
                            if let subtitle {
                                Text(subtitle).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    content
                }
                .padding(Theme.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

// MARK: - Empty state

struct EmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(Color.mise.accent)
                .accessibilityHidden(true)
            Text(title).serifTitle().multilineTextAlignment(.center)
            Text(message)
                .font(Theme.Fonts.body)
                .foregroundStyle(Color.mise.inkSecondary)
                .multilineTextAlignment(.center)
            if let buttonTitle, let action {
                PrimaryButton(title: buttonTitle, action: action)
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Recipe card

struct RecipeCard: View {
    let title: String
    let imageURL: URL?
    let metadata: String

    var body: some View {
        MiseCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                RecipeImage(url: imageURL)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipped()
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title).serifTitle().multilineTextAlignment(.leading)
                    if !metadata.isEmpty {
                        Text(metadata).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                    }
                }
                .padding(Theme.Spacing.m)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Async image with the sunken fork-and-knife placeholder.
struct RecipeImage: View {
    let url: URL?

    var body: some View {
        Color.mise.surfaceSunken
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: "fork.knife")
            .font(.title)
            .foregroundStyle(Color.mise.inkSecondary)
    }
}

// MARK: - Page dots

struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.mise.accent : Color.mise.divider)
                    .frame(width: i == current ? 20 : 8, height: 8)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

// MARK: - Previews

#Preview("Components") {
    ScrollView {
        VStack(spacing: Theme.Spacing.m) {
            RecipeCard(title: "Red Braised Pork Belly", imageURL: nil, metadata: "1 hr 45 min · Chinese")
            ReviewCard(tone: .caution, systemImage: "questionmark.circle", title: "Do you have Shaoxing wine?") {
                Badge(title: "From your pantry", systemImage: "checkmark")
            }
            ReviewCard(tone: .conflict, systemImage: "exclamationmark.triangle", title: "Contains alcohol") { EmptyView() }
            ChipGroup(items: ["Indian", "Chinese", "Thai"], title: { $0 }, isSelected: { $0 == "Thai" }, toggle: { _ in })
            PrimaryButton(title: "Continue") {}
            SecondaryButton(title: "Keep original") {}
            EmptyState(systemImage: "book.closed", title: "No recipes yet", message: "Import one from a link.", buttonTitle: "Import", action: {})
        }
        .padding(Theme.Spacing.gutter)
    }
    .miseScreenBackground()
}

#Preview("Components – dark") {
    VStack(spacing: Theme.Spacing.m) {
        RecipeCard(title: "Chow Mein", imageURL: nil, metadata: "15 min · Chinese")
        ReviewCard(tone: .herb, systemImage: "leaf", title: "You prefer milder food") { Badge(title: "From your pantry") }
        PrimaryButton(title: "Continue") {}
    }
    .padding(Theme.Spacing.gutter)
    .frame(maxHeight: .infinity)
    .background(Color.mise.background)
    .preferredColorScheme(.dark)
}
