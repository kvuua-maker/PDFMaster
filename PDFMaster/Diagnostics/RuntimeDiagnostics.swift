import Foundation

/// On-device, user-visible diagnostics for the voice → intent → URL chain.
/// This exists because the launch path depends on what the recogniser actually
/// heard and what iOS answered for a scheme, neither of which is observable
/// from a TestFlight build without a screen like this.
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
    private let limit = 300

    private init() {}

    func log(_ kind: String, _ text: String) {
        entries.append(.init(at: Date(), kind: kind, text: text))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    func clear() { entries.removeAll() }

    var copyableText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return entries
            .map { "\(formatter.string(from: $0.at)) [\($0.kind)] \($0.text)" }
            .joined(separator: "\n")
    }
}
