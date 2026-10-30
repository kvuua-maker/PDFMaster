import Foundation
import UIKit

extension PDFToolsModel {
    func makeSearchable() {
        guard FreeTier.isPro else { showPaywall = true; return }
        guard let url = results.first else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let output = try await PDFToolsEngine.shared.addOCRTextLayer(url)
                undoStack.append(results)
                results.insert(output, at: 0)
                statusLine = "Додано текстовий шар — файл тепер шукається"
                ocrSourceURL = output
                ocrPages = (try? await PDFToolsEngine.shared.recognizePages(output)) ?? ocrPages
                showOCRDone = true
            } catch {
                alertMessage = (error as? PDFToolsError)?.userMessage ?? "Не вдалося додати текстовий шар."
            }
        }
    }

    func applyHeader() {
        guard let url = results.first, !headerText.isEmpty else { showHeader = false; return }
        showHeader = false
        run { Optional(try await PDFToolsEngine.shared.addHeaderFooter(url, header: self.headerText, footer: "")) }
    }

    func applyLogoWatermark(_ image: UIImage) {
        guard let url = results.first else { return }
        run { Optional(try await PDFToolsEngine.shared.watermarkImage(url, image: image)) }
    }

    func movePage() {
        guard let url = results.first,
              let from = Int(moveFrom), let to = Int(moveTo), from >= 1, to >= 1 else { return }
        showMovePage = false
        run { Optional(try await PDFToolsEngine.shared.movePage(url, from: from - 1, to: to - 1)) }
    }

    func applyCropTo(rect: CGRect) {
        showCrop = false
        guard let url = results.first else { return }
        let pages = cropOnlyFirstPage ? [0] : Array(0..<max(1, PDFToolsEngine.shared.pageCountSync(url)))
        run { Optional(try await PDFToolsEngine.shared.crop(url, normalizedRect: rect, pages: pages)) }
    }

    func useSavedSignature() {
        guard let image = savedSignature, let url = results.first else { return }
        let rect = CGRect(x: 0.55, y: 0.82, width: 0.35, height: 0.1)
        run { Optional(try await PDFToolsEngine.shared.insertSignature(url, signature: image, normalizedRect: rect)) }
    }

    func saveSignatureImage(_ image: UIImage) {
        if let data = image.pngData() {
            UserDefaults.standard.set(data, forKey: "PDFSavedSignature")
        }
    }

    var savedSignature: UIImage? {
        guard let data = UserDefaults.standard.data(forKey: "PDFSavedSignature") else { return nil }
        return UIImage(data: data)
    }

    func applyCrop(_ rect: CGRect) {
        showCrop = false
        guard let url = results.first else { return }
        run { Optional(try await PDFToolsEngine.shared.crop(url, normalizedRect: rect)) }
    }

    func placeAnnotation(_ rect: CGRect) {
        showPlacement = false
        guard let url = results.first else { return }
        let kind = placementKind
        run { Optional(try await PDFToolsEngine.shared.addAnnotation(url, kind: kind, normalizedRect: rect)) }
        releasePlacementImageSoon()
    }

    func startPlacement(_ kind: PDFAnnotationKind) {
        placementKind = kind
        // A wider render keeps small text readable once the page is zoomed in;
        // it is produced once here instead of on every sheet update.
        if let url = results.first {
            placementImage = PDFToolsEngine.shared.pageImageSync(url, maxWidth: 1600)
        } else {
            placementImage = nil
        }
        showPlacement = true
    }

    func cancelPlacement() {
        showPlacement = false
        releasePlacementImageSoon()
    }

    /// The cover keeps drawing its content while it animates out, so the
    /// rendered page is released only after dismissal; reopening the tool in
    /// the meantime keeps the newer render.
    private func releasePlacementImageSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if !showPlacement { placementImage = nil }
        }
    }

    func deleteRangePages() {
        guard let url = results.first else { return }
        let parts = deleteRange.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let first = parts.first else { return }
        let last = parts.count > 1 ? parts[1] : first
        guard first >= 1, last >= first else { return }
        showDeletePage = false
        run { Optional(try await PDFToolsEngine.shared.deletePages(url, indexes: Array((first - 1)...(last - 1)))) }
    }

    func duplicateChosenPage() {
        guard let url = results.first, let index = Int(duplicateIndex), index >= 1 else { return }
        showDuplicatePage = false
        run { Optional(try await PDFToolsEngine.shared.duplicatePage(url, index: index - 1)) }
    }

    func nextSearchMatch() {
        guard !searchMatches.isEmpty else { return }
        viewerPage = searchMatches[searchCursor % searchMatches.count]
        searchCursor += 1
        showViewer = true
    }

    func findPages() {
        guard !searchQuery.isEmpty, let url = results.first else {
            searchMatches = []
            searchResult = nil
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                // 1. Native text layer of the current file.
                var pages = try await PDFToolsEngine.shared.searchPages(url, query: searchQuery)
                // 2. Remembered OCR of this exact file.
                if pages.isEmpty, ocrSourceURL == url {
                    pages = Self.matches(in: ocrPages, query: searchQuery)
                }
                // 3. Fresh OCR over the pages, then search that.
                if pages.isEmpty {
                    let recognised = try await PDFToolsEngine.shared.recognizePages(url)
                    ocrPages = recognised
                    ocrSourceURL = url
                    pages = Self.matches(in: recognised, query: searchQuery)
                }
                Task { @MainActor in
                    RuntimeDiagnostics.shared.log(
                        "PDF",
                        "search \"\(self.searchQuery)\": \(pages.count) pages, ocrIndex=\(self.ocrPages.count)")
                }
                searchMatches = pages
                searchCursor = 0
                searchResult = pages.isEmpty
                    ? "Нічого не знайдено"
                    : "Знайдено на сторінках: \(pages.map { String($0 + 1) }.joined(separator: ", "))"
            } catch {
                searchMatches = []
                searchResult = "Пошук не вдався"
            }
        }
    }

    static func matches(in pages: [Int: String], query: String) -> [Int] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        return pages
            .filter { $0.value.lowercased().contains(needle) }
            .keys
            .sorted()
    }

    func exportText() {
        guard let url = results.first else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let text = try await PDFToolsEngine.shared.text(from: url)
                statusLine = text.isEmpty ? "У файлі немає текстового шару (можливо, це скан)" : String(text.prefix(600))
            } catch {
                alertMessage = (error as? PDFToolsError)?.userMessage ?? "Не вдалося прочитати текст."
            }
        }
    }

    func cropPages() {
        guard let url = results.first else { return }
        run { Optional(try await PDFToolsEngine.shared.crop(url, inset: 10)) }
    }

    func resizeA4() {
        guard let url = results.first else { return }
        run { Optional(try await PDFToolsEngine.shared.resize(url, to: CGSize(width: 595, height: 842))) }
    }

    func resizeLetter() {
        guard let url = results.first else { return }
        run { Optional(try await PDFToolsEngine.shared.resize(url, to: CGSize(width: 612, height: 792))) }
    }

    func addFooters() {
        guard let url = results.first else { return }
        run { Optional(try await PDFToolsEngine.shared.addFooter(url)) }
    }

    func removePassword() {
        guard FreeTier.isPro else { showRemovePassword = false; showPaywall = true; return }
        guard let url = results.first, !passwordText.isEmpty else { showRemovePassword = false; return }
        showRemovePassword = false
        run { Optional(try await PDFToolsEngine.shared.removePassword(url, password: self.passwordText)) }
    }

    func scanPages(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        run { Optional(try await PDFToolsEngine.shared.makePDF(from: images, name: "scan.pdf")) }
    }

    func findInDocument() {
        guard !searchQuery.isEmpty else { searchResult = nil; return }
        isBusy = true
        Task {
            defer { isBusy = false }
            guard let url = results.first else { return }
            do {
                let text = try await PDFToolsEngine.shared.text(from: url)
                let haystack = text.isEmpty
                    ? try await PDFToolsEngine.shared.recognizeText(in: url)
                    : text
                let count = haystack.lowercased().components(separatedBy: searchQuery.lowercased()).count - 1
                searchResult = count > 0 ? "Знайдено збігів: \(count)" : "Нічого не знайдено"
            } catch {
                searchResult = "Пошук не вдався"
            }
        }
    }

    var canRedo: Bool { !redoStack.isEmpty }

    func redo() {
        guard let previous = redoStack.popLast() else { return }
        undoStack.append(results)
        results = previous
    }

    func runOCR() {
        guard FreeTier.isPro else { showPaywall = true; return }
        guard let url = results.first else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let text = try await PDFToolsEngine.shared.recognizeText(in: url)
                ocrPages = try await PDFToolsEngine.shared.recognizePages(url)
                ocrSourceURL = url
                statusLine = text.isEmpty ? "Текст не розпізнано" : String(text.prefix(600))
            } catch {
                alertMessage = (error as? PDFToolsError)?.userMessage ?? "Не вдалося розпізнати текст."
            }
        }
    }

    func exportPNG() {
        guard FreeTier.isPro else { showPaywall = true; return }
        guard let url = results.first else { return }
        run { let pages = try await PDFToolsEngine.shared.images(from: url); return pages.first }
    }

    func splitPages() {
        guard let url = results.first else { return }
        let parts = splitRange.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let first = parts.first else { return }
        let last = parts.count > 1 ? parts[1] : first
        guard first >= 1, last >= first else { showSplit = false; return }
        showSplit = false
        run { Optional(try await PDFToolsEngine.shared.extractPages(from: url, range: (first - 1)...(last - 1))) }
    }

    func deleteChosenPage() {
        guard let url = results.first, let index = Int(deletePageIndex), index >= 1 else { return }
        showDeletePage = false
        run { Optional(try await PDFToolsEngine.shared.deletePages(url, indexes: [index - 1])) }
    }

    func addAnnotation(_ kind: PDFAnnotationKind) {
        guard let url = results.first else { return }
        run { Optional(try await PDFToolsEngine.shared.addAnnotation(url, kind: kind)) }
    }

    func duplicateFirstPage() {
        guard let url = results.first else { return }
        run { Optional(try await PDFToolsEngine.shared.duplicatePage(url, index: 0)) }
    }

    func signatureBackground() -> UIImage? {
        guard let url = results.first else { return nil }
        return PDFToolsEngine.shared.pageImageSync(url)
    }

    func applySignature(image: UIImage, rect: CGRect) {
        guard let url = results.first else { showSignature = false; return }
        showSignature = false
        run { Optional(try await PDFToolsEngine.shared.insertSignature(url, signature: image, normalizedRect: rect)) }
    }

    func rotate(_ url: URL) {
        run { Optional(try await PDFToolsEngine.shared.rotate(url, degrees: 90)) }
    }

    func compress(_ url: URL) {
        run { Optional(try await PDFToolsEngine.shared.compress(url)) }
    }

    var blankIndex: String {
        get { _blankIndex }
        set { _blankIndex = newValue }
    }

    func runBlank() {
        run { Optional(try await PDFToolsEngine.shared.makeBlankPDF()) }
    }

    func mergeFiles(_ urls: [URL]) {
        guard urls.count >= 1 else { return }
        importedPDFs = urls
        run { Optional(try await PDFToolsEngine.shared.merge(urls)) }
    }

    func add(images: [UIImage]) {
        guard !images.isEmpty else { return }
        run { Optional(try await PDFToolsEngine.shared.makePDF(from: images)) }
    }

    func add(image: UIImage) {
        run { Optional(try await PDFToolsEngine.shared.makePDF(from: [image])) }
    }

    func applyWatermark() {
        guard let url = results.first, !watermarkText.isEmpty else { return }
        run { Optional(try await PDFToolsEngine.shared.watermark(url, text: self.watermarkText)) }
    }

    func applyPassword() {
        guard let url = results.first, !passwordText.isEmpty else { return }
        run { Optional(try await PDFToolsEngine.shared.protect(url, password: self.passwordText)) }
    }

    func applyText() {
        guard let url = results.first, !textToInsert.isEmpty else { return }
        run { Optional(try await PDFToolsEngine.shared.addText(url, text: self.textToInsert)) }
    }

    func insertBlankPage() {
        guard let url = results.first, let index = Int(blankIndex) else { return }
        run { Optional(try await PDFToolsEngine.shared.insertBlankPage(url, at: max(0, index - 1))) }
    }

    func extractImages() {
        guard FreeTier.isPro else { showPaywall = true; return }
        guard let url = results.first else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let images = try await PDFToolsEngine.shared.imagesOrRendered(from: url)
                results.insert(contentsOf: images, at: 0)
                statusLine = "Витягнуто зображень: \(images.count)"
            } catch {
                let message = (error as? PDFToolsError)?.userMessage
                    ?? "Не вдалося витягнути зображення. Можливо, файл захищений паролем або пошкоджений."
                alertMessage = message
            }
        }
    }
}
