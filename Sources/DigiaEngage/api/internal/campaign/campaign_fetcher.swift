import Foundation

// Ported from Android `CampaignFetcher.kt` / `DigiaEndpoints`.

enum DigiaEngageEndpoints {
    static let production = "https://api.digia.tech"
    static let sandbox = "https://zaiden-phonematic-unseemly.ngrok-free.dev"
}

struct CampaignFetcher {
    let config: DigiaConfig
    let session: URLSession

    init(config: DigiaConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func fetch() async throws -> [CampaignModel] {
        let base = (config.environment == .sandbox ? DigiaEngageEndpoints.sandbox : DigiaEngageEndpoints.production)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fullURL = "\(base)/api/v1/engage/sdk/getCampaigns"

        log("[CampaignFetcher] fetching: \(fullURL) (env=\(config.environment))")
        guard let url = URL(string: fullURL) else {
            throw DigiaConfigError.network("Invalid getCampaigns URL: \(fullURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "X-Digia-Project-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        log("[CampaignFetcher] response: HTTP \(statusCode)")
        guard statusCode == 200 else {
            throw DigiaConfigError.network("getCampaigns failed: HTTP \(statusCode)")
        }

        let array = try extractCampaignArray(data)
        return array.compactMap { CampaignModel.fromJson($0) }
    }

    private func extractCampaignArray(_ data: Data) throws -> [[String: Any]] {
        let root = try JSONSerialization.jsonObject(with: data)

        if let array = root as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }

        guard let envelope = root as? [String: Any] else {
            throw DigiaConfigError.decodeFailure("getCampaigns response is not an object or array")
        }

        if let nested = (envelope.object("data")?["response"]) as? [Any] {
            return nested.compactMap { $0 as? [String: Any] }
        }
        if let response = envelope["response"] as? [Any] {
            return response.compactMap { $0 as? [String: Any] }
        }

        throw DigiaConfigError.decodeFailure("getCampaigns response missing data.response")
    }

    private func log(_ message: String) {
        guard config.logLevel == .verbose else { return }
        print("Digia \(message)")
    }
}
