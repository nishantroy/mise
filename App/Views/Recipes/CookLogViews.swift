import SwiftUI
import SwiftData
import RecipeKit

/// Recipe detail's "Cooked" card: newest first, a photo or the date and rating per cook.
struct CookedSection: View {
    let saved: SavedRecipe
    @State private var selected: CookLogEntry?

    static let tileSize: CGFloat = 96

    var body: some View {
        SectionCard(title: "Cooked") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Theme.Spacing.s) {
                    ForEach(saved.cookLog.reversed()) { entry in
                        Button { selected = entry } label: { CookLogTile(entry: entry) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("detail.cooked.entry")
                    }
                }
            }
            .scrollClipDisabled()
        }
        .sheet(item: $selected) { entry in
            NavigationStack { CookLogEntryView(saved: saved, entryID: entry.id) }
        }
    }
}

struct CookLogTile: View {
    let entry: CookLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Group {
                if let photo = entry.photo {
                    Color.mise.surfaceSunken.overlay {
                        LocalPhoto(url: CookPhotoStore.shared.thumbnailURL(for: photo), maxPixelSize: 400) {
                            Image(systemName: "photo").foregroundStyle(Color.mise.inkSecondary)
                        }
                    }
                } else {
                    Color.mise.surfaceSunken.overlay {
                        VStack(spacing: Theme.Spacing.xxs) {
                            Text(entry.date, format: .dateTime.day())
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(Color.mise.ink)
                            Text(entry.date, format: .dateTime.month(.abbreviated))
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Color.mise.inkSecondary)
                            RatingChip(rating: entry.rating)
                        }
                    }
                }
            }
            .frame(width: CookedSection.tileSize, height: CookedSection.tileSize)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            Text(entry.date, format: .dateTime.day().month(.abbreviated).year(.twoDigits))
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color.mise.inkSecondary)
                .lineLimit(1)
        }
        .frame(width: CookedSection.tileSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(entry))
        .accessibilityAddTraits(.isButton)
    }

    static func accessibilityLabel(_ entry: CookLogEntry) -> String {
        var parts = ["Cooked " + entry.date.formatted(date: .long, time: .omitted)]
        if let rating = entry.rating, rating != 0 { parts.append(rating > 0 ? "liked" : "didn't like") }
        if entry.photo != nil { parts.append("with photo") }
        return parts.joined(separator: ", ")
    }
}

struct RatingChip: View {
    let rating: Int?

    var body: some View {
        if let rating, rating != 0 {
            Badge(title: rating > 0 ? "Liked" : "Meh", systemImage: rating > 0 ? "hand.thumbsup.fill" : "hand.thumbsdown.fill",
                  tone: rating > 0 ? Color.mise.herb : Color.mise.caution)
        }
    }
}

/// One cook: the photo, how it went, what changed; delete the photo or the whole entry.
struct CookLogEntryView: View {
    let saved: SavedRecipe
    let entryID: UUID

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeleteEntry = false
    @State private var confirmDeletePhoto = false

    private var entry: CookLogEntry? { saved.cookLog.first { $0.id == entryID } }

    var body: some View {
        ScrollView {
            if let entry {
                content(entry)
                    .padding(.horizontal, Theme.Spacing.gutter)
                    .padding(.vertical, Theme.Spacing.m)
            }
        }
        .miseScreenBackground()
        .navigationTitle(entry.map { $0.date.formatted(date: .abbreviated, time: .omitted) } ?? "Cooked")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .confirmationDialog("Delete this photo?", isPresented: $confirmDeletePhoto, titleVisibility: .visible) {
            Button("Delete photo", role: .destructive) {
                CookLogging.deletePhoto(ofEntry: entryID, of: saved)
                try? context.save()
            }
        } message: {
            Text("The entry stays in the log.")
        }
        .confirmationDialog("Delete this cook from the log?", isPresented: $confirmDeleteEntry, titleVisibility: .visible) {
            Button("Delete entry", role: .destructive) {
                CookLogging.deleteEntry(entryID, of: saved)
                try? context.save()
                dismiss()
            }
        } message: {
            Text("Its photo is deleted too. Changes it made to the recipe stay.")
        }
    }

    @ViewBuilder
    private func content(_ entry: CookLogEntry) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if let photo = entry.photo {
                Color.mise.surfaceSunken
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        LocalPhoto(url: CookPhotoStore.shared.url(for: photo), maxPixelSize: 1600) { ProgressView() }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .accessibilityLabel("Photo from this cook")
                    .accessibilityIdentifier("cookLog.photo")
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(entry.date, format: .dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
                    .foregroundStyle(Color.mise.ink)
                HStack(spacing: Theme.Spacing.s) {
                    if let servings = entry.servings { Text("Made for \(servings)") }
                    RatingChip(rating: entry.rating)
                }
                .font(Theme.Fonts.meta)
                .foregroundStyle(Color.mise.inkSecondary)
            }
            if !entry.feedback.isEmpty {
                SectionCard(title: "How it went") {
                    Text(entry.feedback).foregroundStyle(Color.mise.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
            SectionCard(title: "Changes") {
                Text(Self.changes(saved.revision(for: entry)))
                    .foregroundStyle(Color.mise.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: Theme.Spacing.xs) {
                if entry.photo != nil {
                    Button("Delete photo", systemImage: "photo.badge.minus", role: .destructive) { confirmDeletePhoto = true }
                        .buttonStyle(.miseSecondaryWide)
                        .accessibilityIdentifier("cookLog.deletePhoto")
                }
                Button("Delete entry", systemImage: "trash", role: .destructive) { confirmDeleteEntry = true }
                    .buttonStyle(.miseSecondaryWide)
                    .accessibilityIdentifier("cookLog.deleteEntry")
            }
        }
    }

    /// The linked revision's summary without the "Cooked it" prefix.
    static func changes(_ revision: RecipeRevision?) -> String {
        guard let summary = revision?.summary else { return "No changes recorded." }
        if summary == "Cooked it" { return "No changes to the recipe." }
        if summary.hasPrefix("Cooked it: ") { return String(summary.dropFirst("Cooked it: ".count)) }
        return summary
    }
}
