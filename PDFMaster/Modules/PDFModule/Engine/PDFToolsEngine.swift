import Foundation
import PDFKit
import UIKit
import Vision

/// PDF operations used by the PDF Tools screen. Every method is async and does
/// its heavy work off the main actor; results are returned as URLs in a
/// temporary directory so the caller can preview, share, print or save them.
actor PDFToolsEngine {
    static let shared = PDFToolsEngine()

    private var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PDFTools", isDirectory: true)
    }

    private func freshURL(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    // MARK: - Create

    func makePDF(from images: [UIImage], name: String = "images.pdf") throws -> URL {
        let url = try freshURL(name)
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842) // A4 at 72 dpi
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        try renderer.writePDF(to: url) { context in
            for image in images {
                context.beginPage()
                let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
                image.draw(in: CGRect(origin: origin, size: size))
            }
        }
        let kb = fileSizeKB(url)
        Task { @MainActor in RuntimeDiagnostics.shared.log("PDF", "created \(images.count) pages, size = \(kb) KB") }
        return url
    }

    func makeBlankPDF(pages: Int = 1, name: String = "blank.pdf") throws -> URL {
        let url = try freshURL(name)
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        try renderer.writePDF(to: url) { context in
            for _ in 0..<max(1, pages) { context.beginPage() }
        }
        let count = max(1, pages)
        Task { @MainActor in RuntimeDiagnostics.shared.log("PDF", "created blank PDF, \(count) pages") }
        return url
    }

    // MARK: - Combine / split

    func merge(_ urls: [URL], name: String = "merged.pdf") throws -> URL {
        let output = PDFDocument()
        var index = 0
        for url in urls {
            guard let document = PDFDocument(url: url) else { continue }
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                output.insert(page, at: index)
                index += 1
            }
        }
        let url = try freshURL(name)
        guard output.write(to: url) else { throw PDFToolsError.writeFailed }
        Task { @MainActor in RuntimeDiagnostics.shared.log("PDF", "merged \(urls.count) files into \(index) pages") }
        return url
    }

    func extractPages(from url: URL, range: ClosedRange<Int>, name: String = "extract.pdf") throws -> URL {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        let output = PDFDocument()
        var index = 0
        for pageIndex in range {
            guard pageIndex >= 0, pageIndex < document.pageCount, let page = document.page(at: pageIndex) else { continue }
            output.insert(page, at: index)
            index += 1
        }
        guard index > 0 else { throw PDFToolsError.emptyRange }
        let target = try freshURL(name)
        guard output.write(to: target) else { throw PDFToolsError.writeFailed }
        Task { @MainActor in RuntimeDiagnostics.shared.log("PDF", "extracted \(index) pages") }
        return target
    }

    // MARK: - Convert

    func images(from url: URL) throws -> [URL] {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        var results: [URL] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let data = image.pngData() else { continue }
            let target = try freshURL("page-\(index + 1).png")
            try data.write(to: target)
            results.append(target)
        }
        Task { @MainActor in RuntimeDiagnostics.shared.log("PDF", "rendered \(results.count) pages to PNG") }
        return results
    }

    func text(from url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        return document.string ?? ""
    }

    // MARK: - Edit

    func rotate(_ url: URL, degrees: Int) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            page.rotation = (page.rotation + degrees) % 360
        }
        let target = try freshURL("rotated.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    func deletePages(_ url: URL, indexes: [Int]) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        for index in indexes.sorted(by: >) where index >= 0 && index < document.pageCount {
            document.removePage(at: index)
        }
        let target = try freshURL("trimmed.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    func insertBlankPage(_ url: URL, at index: Int) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        let size = CGSize(width: 595, height: 842)
        let renderer = UIGraphicsImageRenderer(size: size)
        let white = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        guard let blank = PDFPage(image: white) else { throw PDFToolsError.writeFailed }
        document.insert(blank, at: max(0, min(index, document.pageCount)))
        let target = try freshURL("with-blank.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    func watermark(_ url: URL, text: String) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        let output = PDFDocument()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let renderer = UIGraphicsImageRenderer(size: bounds.size)
            let composite = renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: bounds.size))
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: 0, y: bounds.size.height)
                context.cgContext.scaleBy(x: 1, y: -1)
                page.draw(with: .mediaBox, to: context.cgContext)
                context.cgContext.restoreGState()

                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 48, weight: .bold),
                    .foregroundColor: UIColor.systemRed.withAlphaComponent(0.28)
                ]
                let string = NSAttributedString(string: text, attributes: attributes)
                let size = string.size()
                context.cgContext.translateBy(x: bounds.width / 2, y: bounds.height / 2)
                context.cgContext.rotate(by: -.pi / 6)
                string.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
            }
            if let pageImage = PDFPage(image: composite) { output.insert(pageImage, at: index) }
        }
        let target = try freshURL("watermarked.pdf")
        guard output.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    // MARK: - Page structure

    func duplicatePage(_ url: URL, index: Int) throws -> URL {
        guard let document = PDFDocument(url: url), let page = document.page(at: index) else {
            throw PDFToolsError.unreadable
        }
        document.insert(page, at: min(index + 1, document.pageCount))
        let target = try freshURL("duplicated.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    func movePage(_ url: URL, from: Int, to: Int) throws -> URL {
        guard let document = PDFDocument(url: url), let page = document.page(at: from) else {
            throw PDFToolsError.unreadable
        }
        document.removePage(at: from)
        document.insert(page, at: max(0, min(to, document.pageCount)))
        let target = try freshURL("reordered.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    func insertImage(_ url: URL, image: UIImage, at index: Int) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsImageRenderer(size: bounds.size)
        let composed = renderer.image { context in
            UIColor.white.setFill()
            context.fill(bounds)
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (bounds.width - size.width) / 2,
                                  y: (bounds.height - size.height) / 2,
                                  width: size.width, height: size.height))
        }
        guard let page = PDFPage(image: composed) else { throw PDFToolsError.writeFailed }
        document.insert(page, at: max(0, min(index, document.pageCount)))
        let target = try freshURL("with-image.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    func crop(_ url: URL, inset: CGFloat) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let media = page.bounds(for: .mediaBox)
            page.setBounds(media.insetBy(dx: inset, dy: inset), for: .mediaBox)
        }
        let target = try freshURL("cropped.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    func resize(_ url: URL, to size: CGSize) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        let bounds = CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let target = try freshURL("resized.pdf")
        try renderer.writePDF(to: target) { context in
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                context.beginPage()
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: 0, y: bounds.height)
                context.cgContext.scaleBy(x: 1, y: -1)
                let media = page.bounds(for: .mediaBox)
                let scale = min(bounds.width / media.width, bounds.height / media.height)
                context.cgContext.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: context.cgContext)
                context.cgContext.restoreGState()
            }
        }
        return target
    }

    // MARK: - Content editing

    func addText(_ url: URL, text: String, pageIndex: Int = 0, fontSize: CGFloat = 18, color: UIColor = .label) throws -> URL {
        guard let document = PDFDocument(url: url), pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else { throw PDFToolsError.unreadable }
        let bounds = page.bounds(for: .mediaBox)
        let rectangle = CGRect(x: 40, y: bounds.height - 120, width: bounds.width - 80, height: 80)
        let annotation = PDFAnnotation(bounds: rectangle, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = UIFont.systemFont(ofSize: fontSize)
        annotation.fontColor = color
        annotation.color = .clear
        page.addAnnotation(annotation)
        let target = try freshURL("with-text.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    func addAnnotation(_ url: URL, kind: PDFAnnotationKind, pageIndex: Int = 0) throws -> URL {
        guard let document = PDFDocument(url: url), pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else { throw PDFToolsError.unreadable }
        let bounds = page.bounds(for: .mediaBox)
        let rectangle = CGRect(x: 60, y: bounds.midY, width: bounds.width - 120, height: 60)
        let annotation = PDFAnnotation(bounds: rectangle, forType: kind.pdfType, withProperties: nil)
        annotation.color = kind.color
        page.addAnnotation(annotation)
        let target = try freshURL("annotated.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    func addFooter(_ url: URL, withDate: Bool = true) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let label = withDate ? "\(index + 1) / \(document.pageCount) · \(formatter.string(from: Date()))"
                                 : "\(index + 1) / \(document.pageCount)"
            let rectangle = CGRect(x: 40, y: 24, width: bounds.width - 80, height: 18)
            let annotation = PDFAnnotation(bounds: rectangle, forType: .freeText, withProperties: nil)
            annotation.contents = label
            annotation.font = UIFont.systemFont(ofSize: 10)
            annotation.fontColor = .gray
            annotation.color = .clear
            page.addAnnotation(annotation)
        }
        let target = try freshURL("with-footer.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    // MARK: - Signature

    /// Draws a saved signature image into the bottom-right of the first page.
    func insertSignature(_ url: URL, signature: UIImage, pageIndex: Int = 0) throws -> URL {
        guard let document = PDFDocument(url: url), pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else { throw PDFToolsError.unreadable }
        let media = page.bounds(for: .mediaBox)
        let width = min(media.width * 0.35, 220)
        let ratio = signature.size.height / max(signature.size.width, 1)
        let rectangle = CGRect(x: media.width - width - 40,
                               y: 48,
                               width: width,
                               height: width * ratio)
        let annotation = PDFAnnotation(bounds: rectangle, forType: .stamp, withProperties: nil)
        annotation.color = .clear
        page.addAnnotation(annotation)
        // The image is composited rather than embedded: PDFKit cannot attach raw
        // bitmaps to an annotation, so the page is re-rendered with the overlay.
        let renderer = UIGraphicsImageRenderer(size: media.size)
        let composed = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: media.size))
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: 0, y: media.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: context.cgContext)
            context.cgContext.restoreGState()
            signature.draw(in: rectangle)
        }
        if let replacement = PDFPage(image: composed) {
            document.removePage(at: pageIndex)
            document.insert(replacement, at: pageIndex)
        }
        let target = try freshURL("signed.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        Task { @MainActor in RuntimeDiagnostics.shared.log("PDF", "signature inserted on page \(pageIndex + 1)") }
        return target
    }

    /// Composites a signature into an explicit normalized rectangle of a page.
    /// The rectangle is in page space with the origin at the top-left, which is
    /// what the drawing canvas reports.
    func insertSignature(_ url: URL, signature: UIImage, pageIndex: Int = 0, normalizedRect: CGRect) throws -> URL {
        guard let document = PDFDocument(url: url), pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else { throw PDFToolsError.unreadable }
        let media = page.bounds(for: .mediaBox)
        let rect = CGRect(
            x: normalizedRect.minX * media.width,
            y: (1 - normalizedRect.maxY) * media.height,
            width: normalizedRect.width * media.width,
            height: normalizedRect.height * media.height
        )
        let renderer = UIGraphicsImageRenderer(size: media.size)
        let composed = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: media.size))
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: 0, y: media.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: context.cgContext)
            context.cgContext.restoreGState()
            signature.draw(in: rect)
        }
        if let replacement = PDFPage(image: composed) {
            document.removePage(at: pageIndex)
            document.insert(replacement, at: pageIndex)
        }
        let target = try freshURL("signed.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        Task { @MainActor in RuntimeDiagnostics.shared.log("PDF", "signature placed at \(rect)") }
        return target
    }

    func saveSignature(_ image: UIImage, name: String = "signature.png") throws -> URL {
        guard let data = image.pngData() else { throw PDFToolsError.writeFailed }
        let url = try freshURL(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Embedded images

    /// Extracts JPEG-encoded images that are actually embedded in the PDF
    /// (photos are normally stored as DCTDecode streams). Rendered page
    /// snapshots are a different operation and live in `images(from:)`.
    func extractEmbeddedImages(from url: URL) throws -> [URL] {
        guard let document = CGPDFDocument(url as CFURL) else { throw PDFToolsError.unreadable }
        var written: [URL] = []
        for pageIndex in 1...max(1, document.numberOfPages) {
            guard let page = document.page(at: pageIndex),
                  let pageDictionary = page.dictionary else { continue }
            var resources: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources), let resources else { continue }
            var xObjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { continue }

            var context = ExtractionContext()
            withUnsafeMutablePointer(to: &context) { pointer in
                CGPDFDictionaryApplyFunction(xObjects, { _, object, info in
                    guard let info else { return }
                    let context = info.assumingMemoryBound(to: ExtractionContext.self)
                    var stream: CGPDFStreamRef?
                    guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
                    guard let dictionary = CGPDFStreamGetDictionary(stream) else { return }
                    var subtype: UnsafePointer<Int8>?
                    guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype),
                          let subtype, String(cString: subtype) == "Image" else { return }
                    var format = CGPDFDataFormat.raw
                    guard let raw = CGPDFStreamCopyData(stream, &format) else { return }
                    let data = raw as Data
                    // Only formats that need no re-encoding are kept verbatim.
                    var filterName: UnsafePointer<Int8>?
                    if CGPDFDictionaryGetName(dictionary, "Filter", &filterName), let filterName {
                        let name = String(cString: filterName)
                        guard name == "DCTDecode" || name == "JPXDecode" else { return }
                    } else {
                        return
                    }
                    context.pointee.chunks.append(data)
                }, pointer)
            }
            for data in context.chunks {
                let target = try freshURL("image-\(pageIndex)-\(written.count + 1).jpg")
                try data.write(to: target)
                written.append(target)
            }
        }
        Task { @MainActor in RuntimeDiagnostics.shared.log("PDF", "extracted \(written.count) embedded images") }
        guard !written.isEmpty else { throw PDFToolsError.emptyRange }
        return written
    }

    // MARK: - Annotations

    struct AnnotationBox: Identifiable {
        let id: Int
        let bounds: CGRect
        let page: CGRect
        let label: String
    }

    func annotations(in url: URL, pageIndex: Int = 0) throws -> [AnnotationBox] {
        guard let document = PDFDocument(url: url), let page = document.page(at: pageIndex) else {
            throw PDFToolsError.unreadable
        }
        let pageBounds = page.bounds(for: .mediaBox)
        return page.annotations.enumerated().map { index, annotation in
            AnnotationBox(id: index,
                          bounds: annotation.bounds,
                          page: pageBounds,
                          label: annotation.contents ?? annotation.type ?? "annotation")
        }
    }

    func pageImage(_ url: URL, pageIndex: Int = 0, width: CGFloat = 900) -> UIImage? {
        guard let document = PDFDocument(url: url), let page = document.page(at: pageIndex) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = width / max(bounds.width, 1)
        return page.thumbnail(of: CGSize(width: width, height: bounds.height * scale), for: .mediaBox)
    }

    func moveAnnotation(_ url: URL, pageIndex: Int = 0, annotationIndex: Int, by offset: CGSize) throws -> URL {
        guard let document = PDFDocument(url: url), let page = document.page(at: pageIndex),
              annotationIndex < page.annotations.count else { throw PDFToolsError.unreadable }
        let annotation = page.annotations[annotationIndex]
        annotation.bounds = annotation.bounds.offsetBy(dx: offset.width, dy: offset.height)
        let target = try freshURL("moved.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    /// Direct extraction, then a rendered-page fallback so every PDF yields
    /// something usable even when its images are stored inside compressed
    /// streams.
    func imagesOrRendered(from url: URL) async throws -> [URL] {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        if document.isLocked { throw PDFToolsError.locked }
        if let extracted = try? extractEmbeddedImages(from: url), !extracted.isEmpty {
            return extracted
        }
        // No standalone image streams (scanned or app-generated PDF): render the
        // pages instead, which always works for a readable document.
        let rendered = try images(from: url)
        guard !rendered.isEmpty else { throw PDFToolsError.noImages }
        return rendered
    }

    // MARK: - Precise geometry

    private func pageRect(from normalized: CGRect, in media: CGRect) -> CGRect {
        CGRect(x: media.minX + normalized.minX * media.width,
               y: media.minY + (1 - normalized.maxY) * media.height,
               width: normalized.width * media.width,
               height: normalized.height * media.height)
    }

    func crop(_ url: URL, normalizedRect: CGRect) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let media = page.bounds(for: .mediaBox)
            let rect = pageRect(from: normalizedRect, in: media)
            guard rect.width > 8, rect.height > 8 else { continue }
            page.setBounds(rect, for: .cropBox)
            page.setBounds(rect, for: .mediaBox)
        }
        let target = try freshURL("cropped.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    func addAnnotation(_ url: URL, kind: PDFAnnotationKind, normalizedRect: CGRect, pageIndex: Int = 0) throws -> URL {
        guard let document = PDFDocument(url: url), pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else { throw PDFToolsError.unreadable }
        let media = page.bounds(for: .mediaBox)
        let rectangle = pageRect(from: normalizedRect, in: media)
        let annotation = PDFAnnotation(bounds: rectangle, forType: kind.pdfType, withProperties: nil)
        annotation.color = kind.color
        if kind == .comment { annotation.contents = "Коментар" }
        page.addAnnotation(annotation)
        let target = try freshURL("annotated.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    /// Page indexes (zero-based) whose text contains the query.
    func searchPages(_ url: URL, query: String) throws -> [Int] {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        let needle = query.lowercased()
        var matches: [Int] = []
        for index in 0..<document.pageCount {
            if let text = document.page(at: index)?.string, text.lowercased().contains(needle) {
                matches.append(index)
            }
        }
        return matches
    }

    // MARK: - Text layer, headers, logos

    /// Writes a searchable text layer into the PDF itself. Glyphs are drawn
    /// directly into the PDF content stream (not into a bitmap), so any reader
    /// can extract and search them after export.
    func addOCRTextLayer(_ url: URL) async throws -> URL {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        if document.isLocked { throw PDFToolsError.locked }

        var pages: [(image: UIImage, lines: [(text: String, bounds: CGRect)], size: CGSize)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let media = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2
            let size = CGSize(width: media.width * scale, height: media.height * scale)
            let image = page.thumbnail(of: size, for: .mediaBox)
            let lines = (try? Self.recognizeLines(in: image)) ?? []
            pages.append((image, lines, size))
        }

        let target = try freshURL("searchable.pdf")
        guard let first = pages.first else { throw PDFToolsError.unreadable }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.size))
        try renderer.writePDF(to: target) { context in
            for page in pages {
                context.beginPage()
                page.image.draw(in: CGRect(origin: .zero, size: page.size))
                for line in page.lines {
                    let box = line.bounds
                    let rect = CGRect(x: box.minX * page.size.width,
                                      y: (1 - box.maxY) * page.size.height,
                                      width: max(box.width * page.size.width, 8),
                                      height: max(box.height * page.size.height, 6))
                    line.text.draw(in: rect, withAttributes: [
                        .font: UIFont.systemFont(ofSize: max(4, rect.height)),
                        .foregroundColor: UIColor.black.withAlphaComponent(0.01)
                    ])
                }
            }
        }
        let lines = pages.reduce(0) { $0 + $1.lines.count }
        Task { @MainActor in
            RuntimeDiagnostics.shared.log("PDF", "OCR text layer: \(pages.count) pages, \(lines) lines")
        }
        return target
    }

    /// Per-page recognised text, used as a search fallback for scanned files.
    func recognizePages(_ url: URL) async throws -> [Int: String] {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        if document.isLocked { throw PDFToolsError.locked }
        var result: [Int: String] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let media = page.bounds(for: .mediaBox)
            let image = page.thumbnail(of: CGSize(width: media.width * 2, height: media.height * 2), for: .mediaBox)
            let lines = (try? Self.recognizeLines(in: image)) ?? []
            result[index] = lines.map(\.text).joined(separator: "\n")
        }
        Task { @MainActor in
            RuntimeDiagnostics.shared.log("PDF", "OCR memory index: \(result.count) pages")
        }
        return result
    }

    private static func recognizeLines(in image: UIImage) throws -> [(text: String, bounds: CGRect)] {
        guard let cgImage = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["uk-UA", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return (candidate.string, observation.boundingBox)
        }
    }

    func addHeaderFooter(_ url: URL, header: String, footer: String, withDate: Bool = true) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let media = page.bounds(for: .mediaBox)
            if !header.isEmpty {
                let rect = CGRect(x: 40, y: media.height - 40, width: media.width - 80, height: 20)
                let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
                annotation.contents = header
                annotation.font = UIFont.systemFont(ofSize: 10)
                annotation.fontColor = .darkGray
                annotation.color = .clear
                page.addAnnotation(annotation)
            }
            if !footer.isEmpty || withDate {
                let label = footer.isEmpty
                    ? "\(index + 1) / \(document.pageCount) · \(formatter.string(from: Date()))"
                    : "\(footer) · \(index + 1) / \(document.pageCount)"
                let rect = CGRect(x: 40, y: 24, width: media.width - 80, height: 18)
                let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
                annotation.contents = label
                annotation.font = UIFont.systemFont(ofSize: 10)
                annotation.fontColor = .gray
                annotation.color = .clear
                page.addAnnotation(annotation)
            }
        }
        let target = try freshURL("header-footer.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    func watermarkImage(_ url: URL, image: UIImage, scale: CGFloat = 0.5) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        let output = PDFDocument()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let media = page.bounds(for: .mediaBox)
            let renderer = UIGraphicsImageRenderer(size: media.size)
            let composed = renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: media.size))
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: 0, y: media.height)
                context.cgContext.scaleBy(x: 1, y: -1)
                page.draw(with: .mediaBox, to: context.cgContext)
                context.cgContext.restoreGState()
                let width = media.width * min(max(scale, 0.1), 1)
                let ratio = image.size.height / max(image.size.width, 1)
                let rect = CGRect(x: (media.width - width) / 2,
                                  y: (media.height - width * ratio) / 2,
                                  width: width,
                                  height: width * ratio)
                image.draw(in: rect, blendMode: .normal, alpha: 0.22)
            }
            if let newPage = PDFPage(image: composed) { output.insert(newPage, at: index) }
        }
        let target = try freshURL("logo-watermark.pdf")
        guard output.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    func deleteAnnotation(_ url: URL, pageIndex: Int = 0, annotationIndex: Int) throws -> URL {
        guard let document = PDFDocument(url: url), let page = document.page(at: pageIndex),
              annotationIndex < page.annotations.count else { throw PDFToolsError.unreadable }
        page.removeAnnotation(page.annotations[annotationIndex])
        let target = try freshURL("annotation-removed.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    func crop(_ url: URL, normalizedRect: CGRect, pages: [Int]) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        for index in pages where index >= 0 && index < document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let media = page.bounds(for: .mediaBox)
            let rect = pageRect(from: normalizedRect, in: media)
            guard rect.width > 8, rect.height > 8 else { continue }
            page.setBounds(rect, for: .cropBox)
            page.setBounds(rect, for: .mediaBox)
        }
        let target = try freshURL("cropped-selected.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        return target
    }

    // MARK: - Password removal

    /// Rewrites a password-protected document without its password. The current
    /// password is required because PDFKit cannot decrypt without it.
    func removePassword(_ url: URL, password: String) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        if document.isLocked {
            guard document.unlock(withPassword: password) else { throw PDFToolsError.locked }
        }
        let target = try freshURL("unprotected.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        Task { @MainActor in RuntimeDiagnostics.shared.log("PDF", "password removed") }
        return target
    }

    // MARK: - Security & size

    func protect(_ url: URL, password: String) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        let target = try freshURL("protected.pdf")
        guard document.write(to: target, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password]) else {
            throw PDFToolsError.writeFailed
        }
        return target
    }

    /// Rewrites the document so unused objects and metadata are dropped; this is
    /// the honest "compression" PDFKit offers without rasterising pages.
    func compress(_ url: URL) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        document.documentAttributes = nil
        let target = try freshURL("compressed.pdf")
        guard document.write(to: target) else { throw PDFToolsError.writeFailed }
        let before = fileSizeKB(url), after = fileSizeKB(target)
        Task { @MainActor in RuntimeDiagnostics.shared.log("PDF", "compressed: \(before) KB -> \(after) KB") }
        return target
    }

    // MARK: - OCR

    func recognizeText(in url: URL, languages: [String] = ["uk-UA", "en-US"]) async throws -> String {
        guard let document = PDFDocument(url: url) else { throw PDFToolsError.unreadable }
        let started = Date()
        var output = ""
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let image = page.thumbnail(of: CGSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
            guard let cgImage = image.cgImage else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            output += lines.joined(separator: "\n") + "\n"
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Task { @MainActor in RuntimeDiagnostics.shared.log("PDF", "OCR completed in \(ms) ms, \(output.count) chars") }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fileSizeKB(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return bytes / 1024
    }
}

enum PDFAnnotationKind: String, CaseIterable {
    case highlight, underline, strikeOut, square, circle, comment

    var pdfType: PDFAnnotationSubtype {
        switch self {
        case .highlight: .highlight
        case .underline: .underline
        case .strikeOut: .strikeOut
        case .square: .square
        case .circle: .circle
        case .comment: .freeText
        }
    }

    var color: UIColor {
        switch self {
        case .highlight: .systemYellow.withAlphaComponent(0.5)
        case .underline, .strikeOut: .systemBlue
        case .square, .circle: .systemRed
        case .comment: .systemGreen
        }
    }
}

extension PDFToolsEngine {
    nonisolated func pageCountSync(_ url: URL) -> Int {
        PDFDocument(url: url)?.pageCount ?? 1
    }

    /// Page 1 as a bitmap. Annotation placement asks for a wider render so the
    /// page stays legible when it is zoomed in.
    nonisolated func pageImageSync(_ url: URL, maxWidth: CGFloat = 900) -> UIImage? {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let width = max(maxWidth, 200)
        let scale: CGFloat = width / max(bounds.width, 1)
        return page.thumbnail(of: CGSize(width: width, height: bounds.height * scale), for: .mediaBox)
    }

    nonisolated func annotationsSync(_ url: URL) -> [AnnotationBox] {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return [] }
        let pageBounds = page.bounds(for: .mediaBox)
        return page.annotations.enumerated().map { index, annotation in
            AnnotationBox(id: index, bounds: annotation.bounds, page: pageBounds,
                          label: annotation.contents ?? "annotation")
        }
    }
}

enum PDFToolsError: Error, Equatable {
    case unreadable, writeFailed, emptyRange, locked, noImages

    var userMessage: String {
        switch self {
        case .locked:
            "Файл захищений паролем. Зніміть пароль і спробуйте ще раз."
        case .unreadable:
            "Не вдалося відкрити файл. Можливо, він пошкоджений."
        case .noImages:
            "У цьому файлі не знайдено окремих зображень."
        case .emptyRange:
            "Не вибрано жодної сторінки."
        case .writeFailed:
            "Не вдалося зберегти результат. Спробуйте ще раз."
        }
    }
}

private struct ExtractionContext {
    var chunks: [Data] = []
}
