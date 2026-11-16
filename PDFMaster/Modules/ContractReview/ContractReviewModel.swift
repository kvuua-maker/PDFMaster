import Foundation
import SwiftUI

struct ReviewPresentation: Identifiable {
    let id = UUID()
    let name: String
    let response: ReviewResponse
}

struct ReviewRecord: Identifiable {
    let id = UUID()
    let name: String
    let date: Date
    let response: ReviewResponse

    var subtitle: String {
        switch response.status {
        case "blank": return "Порожній бланк"
        case "unreadable": return "Нерозбірливий скан"
        default:
            let count = response.findings.count
            return count == 0 ? "Без зауважень" : "\(count) зауважень"
        }
    }
}

/// State of the review flow: pick a contract, OCR it, ask the service, show
/// the risks.
@MainActor
@Observable
final class ContractReviewModel {
    enum Phase {
        case idle
        case working(String)
        case result(ReviewResponse)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var documentName = ""
    private(set) var history: [ReviewRecord] = []
    /// Set when a result is ready; the home screen presents it and clears it.
    var presented: ReviewPresentation?

    private let client = ReviewClient()

    func analyse(url: URL) {
        documentName = url.lastPathComponent
        Task {
            phase = .working("Розпізнаємо текст…")
            do {
                let extraction = try await DocumentTextExtractor.extract(from: url)
                phase = .working("Аналізуємо умови…")
                let response = try await client.analyse(extraction)
                finish(response)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func analyse(imageData: Data, name: String) {
        documentName = name
        Task {
            phase = .working("Розпізнаємо текст…")
            do {
                let extraction = try await DocumentTextExtractor.extract(imageData: imageData)
                phase = .working("Аналізуємо умови…")
                let response = try await client.analyse(extraction)
                finish(response)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func reset() {
        phase = .idle
        presented = nil
        documentName = ""
    }

    func open(_ record: ReviewRecord) {
        documentName = record.name
        presented = ReviewPresentation(name: record.name, response: record.response)
    }

    private func finish(_ response: ReviewResponse) {
        history.insert(ReviewRecord(name: documentName, date: Date(), response: response), at: 0)
        if history.count > 20 { history.removeLast() }
        phase = .idle
        presented = ReviewPresentation(name: documentName, response: response)
    }
}
