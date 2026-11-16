import Foundation

enum ReviewError: LocalizedError {
    case notConfigured
    case requestFailed(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Сервіс перевірки не налаштований"
        case .requestFailed(let text): return "Немає зв'язку з сервісом: \(text)"
        case .badResponse(let text): return text
        }
    }
}

/// Client for POST /v1/review.
struct ReviewClient {
    private static let endpoint = URL(string: "https://178.105.32.46/v1/review")!

    private var token: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "ReviewToken") as? String
        guard let value, !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    func analyse(_ extraction: Extraction) async throws -> ReviewResponse {
        guard let token else { throw ReviewError.notConfigured }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-UA-Token")
        request.httpBody = try JSONEncoder().encode(ReviewPayload(extraction: extraction))

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ReviewError.requestFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ReviewError.badResponse("Некоректна відповідь сервера")
        }
        if http.statusCode == 401 { throw ReviewError.badResponse("Сервіс відхилив ключ доступу") }
        guard http.statusCode == 200 else {
            throw ReviewError.badResponse("Сервіс повернув помилку \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(ReviewResponse.self, from: data)
        } catch {
            throw ReviewError.badResponse("Не вдалося прочитати відповідь")
        }
    }
}
