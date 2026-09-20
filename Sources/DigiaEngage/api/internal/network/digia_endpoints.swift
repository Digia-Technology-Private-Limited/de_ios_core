import Foundation

enum DigiaEndpoints {
    private static let production = "https://app.digia.tech"
    private static let sandbox = "https://dev.digia.tech"

    nonisolated(unsafe) private static var _baseUrl: String = production

    static func configure(_ config: DigiaConfig) {
        _baseUrl = config.environment == .sandbox ? sandbox : production
    }

    /// Resets to production default. Use in tests only.
    static func resetForTest(_ baseUrl: String? = nil) {
        _baseUrl = baseUrl ?? production
    }

    static var campaignBundle: String { "\(_baseUrl)/api/v1/engage/sdk/getCampaignBundle" }
    static var track: String { "\(_baseUrl)/api/v1/engage/sdk/track" }
    static var session: String { "\(_baseUrl)/api/v1/engage/sdk/session" }
    static var submission: String { "\(_baseUrl)/api/v1/engage/sdk/recordSubmission" }
    static var recordComponents: String { "\(_baseUrl)/api/v1/engage/sdk/recordComponents" }
    static var recordPageCapture: String { "\(_baseUrl)/api/v1/engage/sdk/recordPageCapture" }
    static var liveTestConnect: String { "\(_baseUrl)/api/v1/engage/sdk/live/connect" }
    static var liveTestAck: String { "\(_baseUrl)/api/v1/engage/sdk/testInvocation/ack" }
    /// Live-only colour for an in-flight test — a survey's answers, how a
    /// nudge was dismissed. Stored nowhere; relayed to the dashboard that
    /// started the test and dropped if nobody is watching.
    static var liveTestEvent: String { "\(_baseUrl)/api/v1/engage/sdk/testInvocation/event" }
}
