import Foundation
import PDFKit
import UIKit
import Vision

enum ExtractionError: LocalizedError {
    case accessDenied
    case unreadable
    case empty

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Немає доступу до файлу. Виберіть його ще раз через «Обрати договір»"
        case .unreadable: return "Не вдалося відкрити файл"
        case .empty: return "У документі не знайдено тексту — можливо, скан надто темний або порожній"
        }
    }
}

/// Turns a contract into lines with boxes.
///
/// The file from the system picker lives outside the sandbox, so it is copied
/// into the app's temporary folder under a security scope first — without that
/// every read fails. PDFs are read through PDFKit's line selections; images and
/// scanned pages go through Vision on a background task, because nothing
/// non-Sendable may cross an actor boundary.
enum DocumentTextExtractor {
    /// Copies a picker URL into the sandbox; the caller owns the returned file.
    static func localCopy(of url: URL) throws -> URL {
        try copyToTemporary(url)
    }

    static func extract(from url: URL) async throws -> Extraction {
        let local = try copyToTemporary(url)
        defer { try? FileManager.default.removeItem(at: local) }
        return try await extract(fromLocal: local)
    }

    static func extract(fromLocal url: URL) async throws -> Extraction {
        if url.pathExtension.lowercased() == "pdf" {
            return try await extractPDF(url)
        }
        let data = try Data(contentsOf: url)
        return try await extract(imageData: data)
    }

    static func extract(imageData: Data) async throws -> Extraction {
        let recognized = await recognize(data: imageData)
        guard !recognized.lines.isEmpty else { throw ExtractionError.empty }
        let page = OCRPage(index: 0,
                           width: Double(recognized.width),
                           height: Double(recognized.height),
                           lines: recognized.lines,
                           confidence: recognized.confidence)
        return Extraction(pages: [page], engine: .vision)
    }

    @MainActor
    private static func extractPDF(_ url: URL) async throws -> Extraction {
        guard let document = PDFDocument(url: url) else { throw ExtractionError.unreadable }
        var pages: [OCRPage] = []
        var pending: [(index: Int, width: Double, height: Double, data: Data)] = []

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let media = page.bounds(for: .mediaBox)
            if let selection = page.selection(for: media),
               !selection.selectionsByLine().isEmpty {
                let lineSelections = selection.selectionsByLine()
                var lines: [OCRLine] = []
                for selection in lineSelections {
                    guard let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else { continue }
                    let box = selection.bounds(for: page)
                    lines.append(OCRLine(text: text,
                                         x: Double(box.minX / max(media.width, 1)),
                                         y: Double((media.maxY - box.maxY) / max(media.height, 1)),
                                         width: Double(box.width / max(media.width, 1)),
                                         height: Double(box.height / max(media.height, 1))))
                }
                if !lines.isEmpty {
                    pages.append(OCRPage(index: index, width: Double(media.width),
                                         height: Double(media.height), lines: lines, confidence: 100))
                    continue
                }
            }
            // A scanned page: render it once and let Vision read it.
            let target = CGSize(width: 1800, height: 1800 * media.height / max(media.width, 1))
            let image = page.thumbnail(of: target, for: .mediaBox)
            if let data = image.jpegData(compressionQuality: 0.85) {
                pending.append((index, Double(media.width), Double(media.height), data))
            }
        }

        for item in pending {
            let recognized = await recognize(data: item.data)
            pages.append(OCRPage(index: item.index, width: item.width, height: item.height,
                                 lines: recognized.lines, confidence: recognized.confidence))
        }
        pages.sort { $0.index < $1.index }
        guard pages.contains(where: { !$0.lines.isEmpty }) else { throw ExtractionError.empty }
        return Extraction(pages: pages, engine: pending.isEmpty ? .pdf : .vision)
    }

    private static func copyToTemporary(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            throw ExtractionError.accessDenied
        }
        return target
    }

    private static func recognize(data: Data) async
        -> (lines: [OCRLine], confidence: Double, width: Int, height: Int) {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data), let cgImage = image.cgImage else {
                return ([], 0.0, 0, 0)
            }
            if let result = run(cgImage: cgImage, languages: nil), !result.lines.isEmpty {
                return (result.lines, result.confidence, cgImage.width, cgImage.height)
            }
            // Some devices do not have the Ukrainian model; English still reads
            // Latin text and numbers, and the model can work with that.
            if let result = run(cgImage: cgImage, languages: ["en-US"]), !result.lines.isEmpty {
                return (result.lines, result.confidence * 0.9, cgImage.width, cgImage.height)
            }
            return ([], 0.0, cgImage.width, cgImage.height)
        }.value
    }

    private nonisolated static func run(cgImage: CGImage, languages: [String]?)
        -> (lines: [OCRLine], confidence: Double)? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let languages {
            request.recognitionLanguages = languages
        } else {
            let preferred = ["uk-UA", "ru-RU", "en-US"]
            let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
                for: .accurate, revision: request.revision)) ?? []
            let available = preferred.filter { supported.contains($0) }
            request.recognitionLanguages = available.isEmpty ? ["en-US"] : available
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        var lines: [OCRLine] = []
        var scores: [Double] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = observation.boundingBox
            lines.append(OCRLine(text: text,
                                 x: Double(box.minX),
                                 y: Double(1 - box.maxY),
                                 width: Double(box.width),
                                 height: Double(box.height)))
            scores.append(Double(candidate.confidence) * 100)
        }
        let confidence = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
        return (lines, confidence)
    }
}
