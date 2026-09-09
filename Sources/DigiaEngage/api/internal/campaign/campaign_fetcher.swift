import Foundation

enum CampaignFetchFailureCategory: Equatable { case transport, httpStatus, invalidResponse }

struct CampaignFetchError: LocalizedError {
    let category: CampaignFetchFailureCategory
    let endpoint: String
    let statusCode: Int?
    let message: String
    let underlying: Error?
    var errorDescription: String? { message }
}

struct CampaignAPIResponse { let statusCode: Int; let data: Data }
protocol CampaignAPI { func fetchCampaignBundle() async throws -> CampaignAPIResponse }

private struct URLSessionCampaignAPI: CampaignAPI {
    let requestHeaders: [String: String]
    let session: URLSession

    func fetchCampaignBundle() async throws -> CampaignAPIResponse {
        let endpoint = DigiaEndpoints.campaignBundle
        guard let url = URL(string: endpoint) else {
            throw CampaignFetchError(category: .transport, endpoint: endpoint, statusCode: nil, message: "Invalid campaign bundle URL", underlying: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in requestHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = Data("{}".utf8)
        do {
            let (data, response) = try await session.data(for: request)
            return CampaignAPIResponse(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, data: data)
        } catch {
            throw CampaignFetchError(category: .transport, endpoint: endpoint, statusCode: nil, message: "Campaign bundle transport failed: \(error.localizedDescription)", underlying: error)
        }
    }
}

struct CampaignFetcher {
    let api: any CampaignAPI
    init(requestHeaders: [String: String], session: URLSession = .shared) { api = URLSessionCampaignAPI(requestHeaders: requestHeaders, session: session) }
    init(api: any CampaignAPI) { self.api = api }

    func fetch() async throws -> CampaignBundle {
        let endpoint = DigiaEndpoints.campaignBundle
        DigiaLog.verbose("[CampaignFetcher] fetching: \(endpoint)")
        let response = try await api.fetchCampaignBundle()
        guard (200...299).contains(response.statusCode) else {
            throw CampaignFetchError(category: .httpStatus, endpoint: endpoint, statusCode: response.statusCode, message: "Campaign bundle request failed: HTTP \(response.statusCode)", underlying: nil)
        }
        do { return try Self.parse(response.data, devicePlatform: "ios") }
        catch let error as CampaignFetchError { throw error }
        catch {
            throw CampaignFetchError(category: .invalidResponse, endpoint: endpoint, statusCode: response.statusCode, message: "Invalid campaign bundle response: \(error.localizedDescription)", underlying: error)
        }
    }

    static func parse(_ data: Data, devicePlatform: String? = nil) throws -> CampaignBundle {
        let endpoint = DigiaEndpoints.campaignBundle
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CampaignFetchError(category: .invalidResponse, endpoint: endpoint, statusCode: nil, message: "Campaign bundle response is not an object", underlying: nil)
        }
        let bundle: [String: Any]?
        if let data = root["data"] as? [String: Any], let response = data["response"] as? [String: Any] { bundle = response }
        else if let response = root["response"] as? [String: Any] { bundle = response }
        else if root["campaigns"] != nil { bundle = root }
        else { bundle = nil }
        guard let bundle, let campaignValues = bundle["campaigns"] as? [Any] else {
            throw CampaignFetchError(category: .invalidResponse, endpoint: endpoint, statusCode: nil, message: "Campaign bundle is missing campaigns array", underlying: nil)
        }
        let raw = campaignValues.compactMap { $0 as? [String: Any] }
        let designTokens: [String: Any]?
        switch bundle["designTokens"] {
        case nil, is NSNull: designTokens = nil
        case let value as [String: Any]: designTokens = value
        default:
            DigiaLog.warning("[CampaignFetcher] designTokens is not an object; using literals only")
            designTokens = nil
        }
        return CampaignBundle.create(
            rawCampaigns: raw,
            designTokensJSON: designTokens,
            devicePlatform: devicePlatform
        )
    }
}
