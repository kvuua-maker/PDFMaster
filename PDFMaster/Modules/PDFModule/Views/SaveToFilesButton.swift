import SwiftUI
import UniformTypeIdentifiers

/// Saves a produced file into the user's Files app via the system exporter.
struct SaveToFilesButton: View {
    let url: URL
    @State private var isExporting = false
    @State private var preparedURL: URL?

    /// Free users export a watermarked copy; Pro exports the file untouched.
    private var exportURL: URL { preparedURL ?? url }

    var body: some View {
        Button(PDFL10n.t("Зберегти у Файли")) { prepareAndExport() }
            .fileExporter(
                isPresented: $isExporting,
                document: PDFFileDocument(url: exportURL),
                contentType: contentType,
                defaultFilename: url.deletingPathExtension().lastPathComponent
            ) { _ in preparedURL = nil }
    }

    private func prepareAndExport() {
        guard !FreeTier.isPro else {
            preparedURL = nil
            isExporting = true
            return
        }
        Task {
            preparedURL = try? await PDFToolsEngine.shared.watermark(url, text: "PDF Master")
            isExporting = true
        }
    }

    private var contentType: UTType {
        url.pathExtension.lowercased() == "pdf" ? .pdf : .image
    }
}

/// Minimal FileDocument wrapper so any produced file can be exported.
struct PDFFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf, .png, .jpeg] }

    let data: Data

    init(url: URL) {
        data = (try? Data(contentsOf: url)) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
