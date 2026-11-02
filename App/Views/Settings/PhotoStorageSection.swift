import SwiftUI
import SwiftData

/// Settings → Photos: how much the cooking photos take, and a bulk clean-up.
struct PhotoStorageSection: View {
    @Environment(\.modelContext) private var context
    @State private var usage: (photos: Int, bytes: Int64) = (0, 0)
    @State private var confirmTrim = false

    var body: some View {
        Section {
            LabeledContent("Photos", value: "\(usage.photos) · \(ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))")
                .accessibilityIdentifier("settings.photoUsage")
            Button("Keep only the latest photo per recipe", role: .destructive) { confirmTrim = true }
                .disabled(usage.photos == 0)
                .accessibilityIdentifier("settings.trimPhotos")
        } header: {
            Text("Cooking photos")
        } footer: {
            Text("Each photo is stored small (about 150–300 KB). Delete one from a recipe's Cooked section.")
        }
        .onAppear(perform: refresh)
        .confirmationDialog("Keep only the latest photo per recipe?", isPresented: $confirmTrim, titleVisibility: .visible) {
            Button("Delete older photos", role: .destructive) {
                CookLogging.keepLatestPhotos(in: context)
                refresh()
            }
        } message: {
            Text("The cooking log keeps its dates, ratings and notes.")
        }
    }

    private func refresh() { usage = CookPhotoStore.shared.usage() }
}
