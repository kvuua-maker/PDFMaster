import SwiftUI
import UniformTypeIdentifiers

/// File-level PDF actions in their own screen so the main workspace stays
/// small enough for the type checker.
struct PDFFileActionsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var file: URL?
    @State private var results: [URL] = []
    @State private var status: String?
    @State private var isBusy = false
    @State private var showPicker = false
    @State private var blankPrompt = false
    @State private var blankIndex = "1"
    @State private var moverItem: PreviewTarget?
    @State private var previewItem: PreviewTarget?
    @State private var alertMessage: String?
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(PDFL10n.t("Вибрати PDF")) { showPicker = true }
                }
                if file != nil {
                    Section("Дії") {
                        Button(PDFL10n.t("Витягнути зображення")) { extract() }
                        Button(PDFL10n.t("Вставити порожню сторінку")) { blankIndex = "1"; blankPrompt = true }
                        Button(PDFL10n.t("Перемістити анотації пальцем")) { if let file { moverItem = PreviewTarget(url: file) } }
                    }
                }
                if !results.isEmpty {
                    Section("Результати") {
                        ForEach(results, id: \.self) { url in
                            VStack(alignment: .leading) {
                                Text(url.lastPathComponent).lineLimit(1)
                                HStack {
                                    Button(PDFL10n.t("Перегляд")) { previewItem = PreviewTarget(url: url) }
                                    SaveToFilesButton(url: url)
                                }
                            }
                        }
                    }
                }
                if let status {
                    Section("Статус") { Text(status).font(.footnote) }
                }
            }
            .midnightScreen()
            .navigationTitle(PDFL10n.t("Інструменти для файлу"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(PDFL10n.t("Готово")) { dismiss() } } }
            .overlay { if isBusy { ProgressView().padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { outcome in
                guard case let .success(files) = outcome, let first = files.first else { return }
                file = FileImport.copy(first)
            }
            .alert(PDFL10n.t("Номер сторінки для вставки"), isPresented: $blankPrompt) {
                TextField("1", text: $blankIndex)
                Button(PDFL10n.t("Вставити")) { insertBlank() }
                Button(PDFL10n.t("Скасувати"), role: .cancel) {}
            }
            .sheet(item: $moverItem) { item in AnnotationMoverView(url: item.url) }
            .sheet(item: $previewItem) { item in PDFPreviewSheet(url: item.url) }
            .sheet(isPresented: $showPaywall) { ProView() }
            .alert(PDFL10n.t("Помилка"), isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button(PDFL10n.t("OK"), role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    /// Files picked from Files are security-scoped; copy them into the sandbox so
    /// every later read (extraction, rendering) works without the scope.
    private func extract() {
        guard FreeTier.isPro else { showPaywall = true; return }
        guard let file else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let images = try await PDFToolsEngine.shared.imagesOrRendered(from: file)
                results.insert(contentsOf: images, at: 0)
                status = "Витягнуто зображень: \(images.count)"
            } catch {
                alertMessage = (error as? PDFToolsError)?.userMessage
                    ?? "Не вдалося витягнути зображення. Можливо, файл захищений паролем або пошкоджений."
            }
        }
    }

    private func insertBlank() {
        guard let file, let index = Int(blankIndex) else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let updated = try await PDFToolsEngine.shared.insertBlankPage(file, at: max(0, index - 1))
                self.file = updated
                results.insert(updated, at: 0)
                status = "Сторінку вставлено"
            } catch {
                alertMessage = (error as? PDFToolsError)?.userMessage ?? "Не вдалося змінити файл."
            }
        }
    }
}
