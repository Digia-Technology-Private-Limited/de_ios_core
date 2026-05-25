import Foundation

struct CampaignFetcher {
    let config: DigiaConfig

    private var baseURL: String {
        let raw = config.developerConfig?.baseURL ?? "https://app.digia.tech/api/v1"
        return raw.trimmingCharacters(in: .init(charactersIn: "/"))
    }

    func fetch() async throws -> [CampaignModel] {
        guard let url = URL(string: "\(baseURL)/engage/sdk/getCampaigns") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return parseCampaigns(from: data)
    }

    private func parseCampaigns(from data: Data) -> [CampaignModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }

        let array: [[String: Any]]
        if let arr = root as? [[String: Any]] {
            array = arr
        } else if let obj = root as? [String: Any],
                  let dataObj = obj["data"] as? [String: Any],
                  let response = dataObj["response"] as? [[String: Any]] {
            array = response
        } else if let obj = root as? [String: Any],
                  let response = obj["response"] as? [[String: Any]] {
            array = response
        } else {
            return []
        }

        return array.compactMap(CampaignModel.fromJson)
    }
}
