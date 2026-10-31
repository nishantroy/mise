import SwiftUI

/// Design tokens for Mise's "warm kitchen" look (see DESIGN.md).
/// Views use these instead of hard-coded colours, fonts or radii.
enum Theme {
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        /// Screen side gutter.
        static let gutter: CGFloat = 16
    }

    enum Radius {
        static let card: CGFloat = 16
        static let small: CGFloat = 10
    }

    enum Size {
        static let minTap: CGFloat = 44
        static let primaryButtonHeight: CGFloat = 50
        static let reviewBar: CGFloat = 4
        static let stepBadge: CGFloat = 28
    }

    enum Fonts {
        /// Screen headers and onboarding questions.
        static let header: Font = .largeTitle.weight(.semibold)
        /// Recipe titles on cards and detail.
        static let title: Font = .title2.weight(.semibold)
        /// Section titles inside cards.
        static let sectionTitle: Font = .title3.weight(.semibold)
        static let body: Font = .body
        static let meta: Font = .subheadline
        static let caption: Font = .caption
        static let badge: Font = .caption.weight(.semibold)
        static let button: Font = .headline
    }

    /// Opacity of tinted fills such as badges.
    static let tintFillOpacity: Double = 0.12
}

/// Colour tokens from the asset catalog (`Assets.xcassets/Mise/*`), with light and dark variants.
struct MiseColors: Sendable {
    let background = Color("Mise/background")
    let surface = Color("Mise/surface")
    let surfaceSunken = Color("Mise/surfaceSunken")
    let ink = Color("Mise/ink")
    let inkSecondary = Color("Mise/inkSecondary")
    let divider = Color("Mise/divider")
    let accent = Color("Mise/accent")
    let onAccent = Color("Mise/onAccent")
    let herb = Color("Mise/herb")
    let caution = Color("Mise/caution")
    let conflict = Color("Mise/conflict")
}

extension Color {
    static let mise = MiseColors()
}

extension View {
    /// Serif heading style used for titles and questions.
    func serifTitle(_ font: Font = Theme.Fonts.title) -> some View {
        self.font(font).fontDesign(.serif).foregroundStyle(Color.mise.ink)
    }

    /// Paints the cream background behind a List, Form or ScrollView.
    func miseScreenBackground() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Color.mise.background.ignoresSafeArea())
    }

    /// App-wide tint and background colour.
    func miseTheme() -> some View {
        self.tint(Color.mise.accent)
    }
}
