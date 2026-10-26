import Foundation

/// Files chosen in the system picker are security-scoped: the scope ends when
/// the callback returns, so every later read fails. All imported files are
/// copied into the sandbox first and the copy is used from then on.
enum FileImport {
    static func copy(_ source: URL) -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("imported-\(UUID().uuidString)-" + source.lastPathComponent)
        do {
            try Data(contentsOf: source).write(to: target)
            return target
        } catch {
            return source
        }
    }
}
