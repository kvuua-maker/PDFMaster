import Foundation

/// On-device log that survives a crash. Each line carries its own timestamp and
/// is appended to a file in Documents, so a relaunch shows exactly what happened
/// before the crash — including the real time of every event.
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

    private let stampFormat = "yyyy-MM-dd HH:mm:ss.SSS"

    private var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("diagnostics.log")
    }

    private func stampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = stampFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    private func displayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }

    private init() {
        let restored = loadFromDisk()
        if restored > 0 {
            entries.append(Entry(at: Date(), kind: "log", text: "restored \(restored) lines from a previous session"))
        }
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
        let formatter = stampFormatter()
        return entries
            .map { "\(formatter.string(from: $0.at)) [\($0.kind)] \($0.text)" }
            .joined(separator: "\n")
    }

    private func appendToDisk(_ entry: Entry) {
        guard let fileURL else { return }
        let line = "\(stampFormatter().string(from: entry.at)) [\(entry.kind)] \(entry.text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// Parses the persisted lines, keeping each line's own time.
    @discardableResult
    private func loadFromDisk() -> Int {
        guard let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
        let formatter = stampFormatter()
        var loaded: [Entry] = []
        for line in text.split(separator: "\n").suffix(limit) {
            guard let close = line.firstIndex(of: "]") else { continue }
            let head = line[..<close]
            guard let open = head.firstIndex(of: "[") else { continue }
            let timePart = head[..<open].trimmingCharacters(in: .whitespaces)
            let kind = String(head[head.index(after: open)...])
            let body = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            let date = formatter.date(from: timePart) ?? Date()
            loaded.append(Entry(at: date, kind: kind, text: body))
        }
        entries = loaded
        return loaded.count
    }
}
