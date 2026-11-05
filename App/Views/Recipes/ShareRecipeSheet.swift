import SwiftUI
import RecipeKit

/// The photo the "Share recipe" sheet offers to include.
struct SharePhoto: Identifiable {
    let id = UUID()
    let url: URL
}

/// Before sharing a recipe that has a photo: "Include my photo" (on by default). Recipes without
/// a photo go straight to the share sheet.
struct ShareRecipeSheet: View {
    let title: String
    let photoURL: URL
    /// The photo is one a friend shared, not the user's own.
    var photoIsShared = false
    var onShare: (_ includePhoto: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var includePhoto = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                MiseCard {
                    HStack(spacing: Theme.Spacing.s) {
                        LocalPhoto(url: photoURL, maxPixelSize: 300) { Color.mise.surfaceSunken }
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                            .opacity(includePhoto ? 1 : 0.35)
                            .accessibilityHidden(true)
                        Text(title).serifTitle().lineLimit(3)
                    }
                }
                MiseCard {
                    Toggle(isOn: $includePhoto) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(photoIsShared ? "Include the photo" : "Include my photo").foregroundStyle(Color.mise.ink)
                            Text("Adds up to about 400 KB to the file.")
                                .font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                        }
                    }
                    .tint(Color.mise.accent)
                    .accessibilityIdentifier("shareRecipe.includePhoto")
                }
                Text("Friends with Mise can open the file and save the recipe. Others get it as text in Messages or Mail. Your pantry, history, cooking log and ratings aren't included.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color.mise.inkSecondary)
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.m)
        }
        .miseScreenBackground()
        .safeAreaInset(edge: .bottom) {
            Button {
                onShare(includePhoto)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.misePrimary)
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.s)
            .background(Color.mise.background)
            .accessibilityIdentifier("shareRecipe.share")
        }
        .navigationTitle("Share recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
    }
}

#Preview("Light") {
    NavigationStack {
        ShareRecipeSheet(title: "Pepper Chicken", photoURL: URL(filePath: "/missing.heic")) { _ in }
    }
}

#Preview("Dark") {
    NavigationStack {
        ShareRecipeSheet(title: "Pepper Chicken", photoURL: URL(filePath: "/missing.heic"), photoIsShared: true) { _ in }
    }
    .preferredColorScheme(.dark)
}
