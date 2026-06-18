import Foundation

enum DigiaEndpoints {
    private static let production = "https://app.digia.tech"
    private static let sandbox = "https://dev.digia.tech"

    nonisolated(unsafe) private static var _baseUrl: String = production

    static func configure(_ config: DigiaConfig) {
        _baseUrl =
            (config.developerConfig?.baseURL
            ?? (config.environment == .sandbox ? sandbox : production))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Resets to production default. Use in tests only.
    static func resetForTest(_ baseUrl: String? = nil) {
        _baseUrl = baseUrl ?? production
    }

    static var campaigns: String { "\(_baseUrl)/api/v1/engage/sdk/getCampaigns" }
    static var track: String { "\(_baseUrl)/api/v1/engage/sdk/track" }
    static var session: String { "\(_baseUrl)/api/v1/engage/sdk/session" }
    static var submission: String { "\(_baseUrl)/api/v1/engage/sdk/recordSubmission" }
}
