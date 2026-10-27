import SwiftUI
import VisionKit

/// System document scanner: detects page edges, corrects perspective and
/// returns clean scans, which are then assembled into a PDF.
struct DocumentScannerView: UIViewControllerRepresentable, @unchecked Sendable {
    let onFinish: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        init(_ parent: DocumentScannerView) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            var pages: [UIImage] = []
            for index in 0..<scan.pageCount {
                pages.append(scan.imageOfPage(at: index))
            }
            let view = parent
            MainActor.assumeIsolated {
                view.onFinish(pages)
                view.dismiss()
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            let view = parent
            MainActor.assumeIsolated { view.dismiss() }
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            let view = parent
            MainActor.assumeIsolated {
                RuntimeDiagnostics.shared.log("scanner", "failed: \(error)")
                view.dismiss()
            }
        }
    }
}
