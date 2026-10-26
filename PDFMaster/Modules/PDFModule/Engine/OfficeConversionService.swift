import Foundation

/// Converts Word/Excel documents to PDF on the assistant server, where
/// LibreOffice renders the real document (iOS has no public converter).
struct OfficeConversionService {
    static let shared = OfficeConversionService()

    enum Failure: Error { case unreadableFile, missingToken, badResponse }

    func convert(_ url: URL) async throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let token = (Bundle.main.object(forInfoDictionaryKey: "UAAPIToken") as? String) ?? ""
        guard !token.isEmpty else {
            Task { @MainActor in
                RuntimeDiagnostics.shared.log("office", "missing UAAPIToken in Info.plist")
            }
            throw Failure.missingToken
        }

        var request = URLRequest(url: URL(string: "https://178.105.32.46/v1/office/convert")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-UA-Token")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "fileName": url.lastPathComponent,
            "base64": data.base64EncodedString()
        ])

        let (payload, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              payload.starts(with: [0x25, 0x50, 0x44, 0x46]) else { throw Failure.badResponse }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pdf")
        try? FileManager.default.removeItem(at: output)
        try payload.write(to: output)
        await MainActor.run {
            RuntimeDiagnostics.shared.log("PDF", "office converted: \(url.lastPathComponent) -> \(payload.count / 1024) KB")
        }
        return output
    }
}
