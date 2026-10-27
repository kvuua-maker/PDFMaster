import Foundation

/// On-device log that also survives a crash: every entry is appended to a file
/// in Documents, so a relaunch can show what happened right before the crash.
@MainActor
@Observable
final class RuntimeDiagnostics {
    static let shared = RuntimeDiagnostics()

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let kind: String
        let text: String
    }

    private(set) var entries: [Entry] = []
    private let limit = 400

    private var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("diagnostics.log")
    }

    private func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }

    private init() {
        loadFromDisk()
        log("app", "session started")
    }

    func log(_ kind: String, _ text: String) {
        let entry = Entry(at: Date(), kind: kind, text: text)
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        appendToDisk(entry)
    }

    func clear() {
        entries.removeAll()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    var copyableText: String {
        let formatter = formatter()
        return entries
            .map { "\(formatter.string(from: $0.at)) [\($0.kind)] \($0.text)" }
            .joined(separator: "\n")
    }

    private func appendToDisk(_ entry: Entry) {
        guard let fileURL else { return }
        let line = "\(formatter().string(from: entry.at)) [\(entry.kind)] \(entry.text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    private func loadFromDisk() {
        guard let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let parsed = text.split(separator: "\n").suffix(limit).map { line -> Entry in
            let parts = line.split(separator: "]", maxSplits: 1, omittingEmptySubsequences: false)
            let kind = parts.first.map { String($0).split(separator: "[").last.map(String.init) ?? "log" } ?? "log"
            let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : String(line)
            return Entry(at: Date(), kind: kind, text: rest)
        }
        entries = Array(parsed)
    }
}
