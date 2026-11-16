import Foundation
import SwiftUI

/// One saved review: the answer from the service, the source document it came
/// from, and the findings the user marked as "not a risk".
struct StoredRecord: Identifiable, Codable {
    let id: UUID
    var name: String
    var date: Date
    var response: ReviewResponse
    /// File name inside the store's sources folder (PDF or image).
    var sourceFile: String?
    var dismissed: [String]

    var visibleFindings: [ReviewFinding] {
        response.findings.filter { !dismissed.contains($0.id) }
    }

    var subtitle: String {
        switch response.status {
        case "blank": return "Порожній бланк"
        case "unreadable": return "Нерозбірливий скан"
        default:
            let count = visibleFindings.count
            return count == 0 ? "Без зауважень" : "\(count) зауважень"
        }
    }
}

/// History of reviews, persisted between launches.
///
/// The answer, the original document and the dismissed findings live together:
/// reopening a record must still work after the temporary file from the picker
/// has gone away, so the source is copied into Application Support.
@MainActor
@Observable
final class ReviewStore {
    static let shared = ReviewStore()

    private(set) var records: [StoredRecord] = []

    private let root: URL
    private let sources: URL
    private let indexURL: URL
    private let limit = 30

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("ContractReview", isDirectory: true)
        sources = root.appendingPathComponent("Sources", isDirectory: true)
        indexURL = root.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Reading

    func record(id: UUID) -> StoredRecord? {
        records.first { $0.id == id }
    }

    func sourceURL(for record: StoredRecord) -> URL? {
        guard let file = record.sourceFile else { return nil }
        let url = sources.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Writing

    @discardableResult
    func add(name: String, response: ReviewResponse,
             copying sourceURL: URL? = nil, imageData: Data? = nil) -> StoredRecord {
        let id = UUID()
        var file: String?
        if let sourceURL, let copied = copy(sourceURL, id: id) {
            file = copied
        } else if let imageData, let written = write(imageData, id: id, ext: "jpg") {
            file = written
        }
        let record = StoredRecord(id: id, name: name, date: Date(), response: response,
                                  sourceFile: file, dismissed: [])
        records.insert(record, at: 0)
        if records.count > limit {
            for dropped in records[limit...] { removeFiles(for: dropped) }
            records = Array(records.prefix(limit))
        }
        save()
        return record
    }

    func dismiss(_ findingID: String, in recordID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        guard !records[index].dismissed.contains(findingID) else { return }
        records[index].dismissed.append(findingID)
        save()
    }

    func restore(_ findingID: String, in recordID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[index].dismissed.removeAll { $0 == findingID }
        save()
    }

    func remove(_ recordID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        removeFiles(for: records[index])
        records.remove(at: index)
        save()
    }

    // MARK: - Disk

    private func copy(_ url: URL, id: UUID) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "pdf" : url.pathExtension
        let name = "\(id.uuidString).\(ext)"
        let target = sources.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: url, to: target)
            return name
        } catch {
            return nil
        }
    }

    private func write(_ data: Data, id: UUID, ext: String) -> String? {
        let name = "\(id.uuidString).\(ext)"
        let target = sources.appendingPathComponent(name)
        do {
            try data.write(to: target, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    private func removeFiles(for record: StoredRecord) {
        guard let file = record.sourceFile else { return }
        try? FileManager.default.removeItem(at: sources.appendingPathComponent(file))
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([StoredRecord].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
