import SwiftUI
import UIKit

/// Shares a file. Free users share a watermarked copy, Pro users share the file
/// untouched — the same rule as saving to Files.
struct ExportShareButton: View {
    let url: URL
    var title: String = "Поділитися"

    @State private var preparedURL: URL?
    @State private var isSharing = false
    @State private var isPreparing = false

    var body: some View {
        Button(title) { prepare() }
            .disabled(isPreparing)
            .sheet(isPresented: $isSharing) {
                if let preparedURL {
                    ActivityView(items: [preparedURL])
                }
            }
    }

    private func prepare() {
        guard !FreeTier.isPro else {
            preparedURL = url
            isSharing = true
            return
        }
        isPreparing = true
        Task {
            preparedURL = try? await PDFToolsEngine.shared.watermark(url, text: "PDF Master")
            isPreparing = false
            isSharing = true
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
