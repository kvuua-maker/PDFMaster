import SwiftUI
import QuickLook
import UniformTypeIdentifiers

/// Dedicated screen for Word/Excel conversion so the main PDF view stays small.
struct OfficeConvertView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isBusy = false
    @State private var status: String?
    @State private var result: URL?
    @State private var showImporter = false
    @State private var preview: PreviewTarget?
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(PDFL10n.t("Вибрати Word або Excel")) { showImporter = true }
                    Text(FreeTier.usageMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !FreeTier.isPro {
                        Button("Отримати повний доступ за \(ProStore.shared.priceLabel)") { showPaywall = true }
                    }
                }
                if let result {
                    Section("Результат") {
                        Text(result.lastPathComponent)
                        Button(PDFL10n.t("Перегляд")) { preview = PreviewTarget(url: result) }
                        ExportShareButton(url: result, title: PDFL10n.t("Поділитися"))
                    }
                }
                if let status {
                    Section("Статус") { Text(status).font(.footnote) }
                }
            }
            .midnightScreen()
            .navigationTitle(PDFL10n.t("Office → PDF"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(PDFL10n.t("Готово")) { dismiss() } } }
            .overlay { if isBusy { ProgressView().padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: ["docx", "doc", "xlsx", "xls", "rtf", "odt"]
                            .compactMap { UTType(filenameExtension: $0) },
                          allowsMultipleSelection: false) { outcome in
                guard case let .success(files) = outcome, let file = files.first else { return }
                Task { await convert(FileImport.copy(file)) }
            }
            .sheet(item: $preview) { item in PDFPreviewSheet(url: item.url) }
            .sheet(isPresented: $showPaywall) { ProView() }
        }
    }

    private func convert(_ url: URL) async {
        guard FreeTier.canConvert else {
            status = FreeTier.limitMessage
            showPaywall = true
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            result = try await OfficeConversionService.shared.convert(url)
            FreeTier.registerConversion()
            status = "Готово · \(FreeTier.usageMessage)"
        } catch {
            status = "Не вдалося: \(error)"
        }
    }
}
