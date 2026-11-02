import SwiftUI
import PhotosUI
import UIKit

/// "Add a photo" in "I made this": take one with the camera or pick one from the library (the
/// picker runs out of process, so no library permission is needed). The photo is downscaled and
/// stripped of metadata straight away and kept in memory; it's written when the cook is saved.
struct CookPhotoSection: View {
    @Binding var photo: ProcessedCookPhoto?

    @State private var libraryItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var isProcessing = false
    @State private var failed = false

    private var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        MiseCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Add a photo").font(.headline).foregroundStyle(Color.mise.ink)
                if let photo, let preview = UIImage(data: photo.thumbnail) {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                        .accessibilityLabel("Your photo")
                        .accessibilityIdentifier("adjust.photo.preview")
                }
                if isProcessing {
                    HStack(spacing: Theme.Spacing.xs) {
                        ProgressView()
                        Text("Preparing the photo…")
                    }
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color.mise.inkSecondary)
                }
                if failed {
                    Label("Couldn't read that photo. Try another.", systemImage: "exclamationmark.triangle")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Color.mise.conflict)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.s) { buttons }
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) { buttons }
                }
            }
        }
        .disabled(isProcessing)
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                libraryItem = nil
                await process(data)
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { image in
                showingCamera = false
                guard let image else { return }
                // Orientation travels in the JPEG's EXIF and is applied when downscaling.
                Task { await process(image.jpegData(compressionQuality: 0.9)) }
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if cameraAvailable {
            Button { showingCamera = true } label: {
                Label(photo == nil ? "Take a photo" : "Retake", systemImage: "camera")
                    .frame(minHeight: Theme.Size.minTap)
            }
            .accessibilityIdentifier("adjust.photo.camera")
        }
        let libraryTitle = photo == nil ? "Choose from library" : "Choose another"
        PhotosPicker(selection: $libraryItem, matching: .images, preferredItemEncoding: .current) {
            Label(libraryTitle, systemImage: "photo.on.rectangle")
                .frame(minHeight: Theme.Size.minTap)
        }
        .accessibilityIdentifier("adjust.photo.library")
        if photo != nil {
            Button(role: .destructive) { photo = nil } label: {
                Label("Remove", systemImage: "xmark.circle").frame(minHeight: Theme.Size.minTap)
            }
            .accessibilityIdentifier("adjust.photo.remove")
        }
    }

    private func process(_ data: Data?) async {
        guard let data else {
            failed = true
            return
        }
        isProcessing = true
        failed = false
        let processed = await Task.detached(priority: .userInitiated) { CookPhotoProcessor.process(data) }.value
        isProcessing = false
        if let processed { photo = processed } else { failed = true }
    }
}

/// The system camera, for one still photo.
struct CameraPicker: UIViewControllerRepresentable {
    var onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}
