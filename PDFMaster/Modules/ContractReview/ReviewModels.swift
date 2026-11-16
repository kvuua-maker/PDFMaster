import Foundation

/// One OCR line with a normalised box (0…1, top-left origin) — the same space
/// the PDF annotation engine uses.
struct OCRLine: Sendable {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct OCRPage: Sendable {
    let index: Int
    let width: Double
    let height: Double
    let lines: [OCRLine]
    /// 0…100. Text taken from a PDF text layer counts as 100.
    let confidence: Double
}

enum OCREngine: String, Sendable {
    case pdf
    case vision
}

struct Extraction: Sendable {
    let pages: [OCRPage]
    let engine: OCREngine

    var confidence: Double {
        guard !pages.isEmpty else { return 0 }
        let total = pages.reduce(0.0) { $0 + $1.confidence * Double($1.lines.count) }
        let lines = pages.reduce(0) { $0 + $1.lines.count }
        return lines > 0 ? total / Double(lines) : 0
    }
}

// MARK: - Request

struct ReviewPayload: Encodable {
    struct Meta: Encodable {
        let confidence: Double
        let engine: String
    }
    struct Line: Encodable {
        let text: String
        let x: Double
        let y: Double
        let w: Double
        let h: Double
    }
    struct Page: Encodable {
        let index: Int
        let width: Double
        let height: Double
        let lines: [Line]
    }

    let mode = "auto"
    let locale = "uk"
    let meta: Meta
    let pages: [Page]

    init(extraction: Extraction) {
        meta = Meta(confidence: extraction.confidence,
                    engine: extraction.engine.rawValue)
        pages = extraction.pages.map { page in
            Page(index: page.index, width: page.width, height: page.height,
                 lines: page.lines.map {
                     Line(text: $0.text, x: $0.x, y: $0.y, w: $0.width, h: $0.height)
                 })
        }
    }
}

// MARK: - Response

struct ReviewAnchor: Codable {
    let page: Int
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    let score: Double?
}

struct ReviewFinding: Codable, Identifiable {
    let id: String
    let category: String?
    let severity: String
    let title: String
    let explanation: String
    let quote: String
    let anchored: Bool?
    let anchors: [ReviewAnchor]?
    let anchorScore: Double?

    var pageNumber: Int? {
        anchors?.first.map { $0.page + 1 }
    }
}

struct ReviewMissing: Codable, Identifiable {
    let id: String
    let title: String
    let explanation: String?
}

struct ReviewStats: Codable {
    let pages: Int?
    let findings: Int?
    let anchored: Int?
    let ocrScore: Double?
    let engine: String?
    let ms: Int?
}

struct ReviewResponse: Codable {
    let status: String
    let message: String?
    let riskLevel: String?
    let findings: [ReviewFinding]
    let missing: [ReviewMissing]
    let stats: ReviewStats?

    var isUsable: Bool { status == "ok" }
}
