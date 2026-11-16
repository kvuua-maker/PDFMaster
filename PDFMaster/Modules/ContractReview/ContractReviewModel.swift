import Foundation
import SwiftUI

struct RecordPresentation: Identifiable {
    let id: UUID
}

/// State of the review flow: pick a contract, OCR it, ask the service, save the
/// record and show the risks.
@MainActor
@Observable
final class ContractReviewModel {
    enum Phase {
        case idle
        case working(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    var presented: RecordPresentation?

    private let client = ReviewClient()
    private let store = ReviewStore.shared

    var records: [StoredRecord] { store.records }

    func analyse(url: URL) {
        Task {
            phase = .working("Розпізнаємо текст…")
            do {
                // One local copy is used for reading and for keeping the source:
                // the picker URL stops being valid as soon as this call returns.
                let local = try DocumentTextExtractor.localCopy(of: url)
                defer { try? FileManager.default.removeItem(at: local) }
                let extraction = try await DocumentTextExtractor.extract(fromLocal: local)
                phase = .working("Аналізуємо умови…")
                let response = try await client.analyse(extraction)
                let record = store.add(name: url.lastPathComponent, response: response, copying: local)
                phase = .idle
                presented = RecordPresentation(id: record.id)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func analyse(imageData: Data, name: String) {
        Task {
            phase = .working("Розпізнаємо текст…")
            do {
                let extraction = try await DocumentTextExtractor.extract(imageData: imageData)
                phase = .working("Аналізуємо умови…")
                let response = try await client.analyse(extraction)
                let record = store.add(name: name, response: response, imageData: imageData)
                phase = .idle
                presented = RecordPresentation(id: record.id)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func open(_ record: StoredRecord) {
        presented = RecordPresentation(id: record.id)
    }

    func reset() {
        phase = .idle
        presented = nil
    }
}
