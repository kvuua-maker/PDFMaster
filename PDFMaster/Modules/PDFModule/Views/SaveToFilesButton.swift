import SwiftUI
import UniformTypeIdentifiers

/// Saves a produced file into the user's Files app via the system exporter.
struct SaveToFilesButton: View {
    let url: URL
    @State private var isExporting = false

    var body: some View {
        Button(PDFL10n.t("Зберегти у Файли")) { isExporting = true }
            .fileExporter(
                isPresented: $isExporting,
                document: PDFFileDocument(url: url),
                contentType: contentType,
                defaultFilename: url.deletingPathExtension().lastPathComponent
            ) { _ in }
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
