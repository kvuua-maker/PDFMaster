import PhotosUI
import UniformTypeIdentifiers
import SwiftUI

/// PHPicker wrapper: the most stable, permission-light way to read photos.
/// UIImagePickerController's library mode is deprecated and crashes on some
/// recent iOS builds, so the app never uses it for the gallery.
struct SystemPhotoPicker: UIViewControllerRepresentable {
    let onPicked: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 20
        configuration.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: SystemPhotoPicker
        init(_ parent: SystemPhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                parent.dismiss()
                return
            }
            Task { @MainActor in
                var images: [UIImage] = []
                for result in results {
                    let provider = result.itemProvider
                    let data: Data? = await withCheckedContinuation { continuation in
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                            continuation.resume(returning: data)
                        }
                    }
                    if let data, let image = UIImage(data: data) { images.append(image) }
                }
                parent.onPicked(images)
                parent.dismiss()
            }
        }
    }
}
