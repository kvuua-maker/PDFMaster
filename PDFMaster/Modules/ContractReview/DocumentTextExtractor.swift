import Foundation
import PDFKit
import UIKit
import Vision

enum ExtractionError: LocalizedError {
    case unreadable
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Не вдалося відкрити файл"
        case .empty: return "У документі не знайдено тексту"
        }
    }
}

/// Turns a contract into lines with boxes.
///
/// PDF text layers are read with PDFKit; pages without a text layer (scans,
/// photos) and picked images go through Vision, which is the same OCR the rest
/// of the app already uses. PDFKit stays on the main actor; Vision runs on a
/// detached task over image data, so nothing non-Sendable crosses threads.
enum DocumentTextExtractor {
    @MainActor
    static func extract(from url: URL) async throws -> Extraction {
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
        return Extraction(pages: pages)
    }

    static func extract(imageData: Data) async throws -> Extraction {
        let recognized = await recognize(data: imageData)
        guard !recognized.lines.isEmpty else { throw ExtractionError.empty }
        let page = OCRPage(index: 0,
                           width: Double(recognized.width),
                           height: Double(recognized.height),
                           lines: recognized.lines,
                           confidence: recognized.confidence)
        return Extraction(pages: [page])
    }

    private static func recognize(data: Data) async
        -> (lines: [OCRLine], confidence: Double, width: Int, height: Int) {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data), let cgImage = image.cgImage else {
                return ([], 0.0, 0, 0)
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["uk-UA", "ru-RU", "en-US"]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return ([], 0.0, 0, 0)
            }
            let observations = request.results ?? []
            var lines: [OCRLine] = []
            var scores: [Double] = []
            for observation in observations {
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
            return (lines, confidence, cgImage.width, cgImage.height)
        }.value
    }
}
