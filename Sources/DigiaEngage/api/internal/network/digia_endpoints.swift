import Foundation

enum DigiaEndpoints {
    private static let production = "https://app.digia.tech"
    private static let sandbox = "https://dev.digia.tech"

    nonisolated(unsafe) private static var _environmentRoot: String = production
    nonisolated(unsafe) private static var _testRoot: String? = nil
    nonisolated(unsafe) private static var _initialized: Bool = false

    static var isInitialized: Bool { _initialized }

    static func configure(_ config: DigiaConfig) {
        _environmentRoot = config.environment == .sandbox ? sandbox : production
        _initialized = true
    }

    static func setTestRoot(_ rootUrl: String) throws {
        if _initialized {
            throw DigiaTestKit.Error.alreadyInitialized
        }
        _testRoot = try normalizeRoot(rootUrl)
    }

    /// Resets all endpoint and test state to defaults. Use in tests only.
    static func resetForTest() {
        _environmentRoot = production
        _testRoot = nil
        _initialized = false
    }

    static var baseUrl: String { _testRoot ?? _environmentRoot }

    static var campaignBundle: String { "\(baseUrl)/api/v1/engage/sdk/getCampaignBundle" }
    static var track: String { "\(baseUrl)/api/v1/engage/sdk/track" }
    static var session: String { "\(baseUrl)/api/v1/engage/sdk/session" }
    static var submission: String { "\(baseUrl)/api/v1/engage/sdk/recordSubmission" }
    static var recordComponents: String { "\(baseUrl)/api/v1/engage/sdk/recordComponents" }
    static var recordPageCapture: String { "\(baseUrl)/api/v1/engage/sdk/recordPageCapture" }
    static var liveTestConnect: String { "\(baseUrl)/api/v1/engage/sdk/live/connect" }
    static var liveTestAck: String { "\(baseUrl)/api/v1/engage/sdk/testInvocation/ack" }
    /// Live-only colour for an in-flight test — a survey's answers, how a
    /// nudge was dismissed. Stored nowhere; relayed to the dashboard that
    /// started the test and dropped if nobody is watching.
    static var liveTestEvent: String { "\(baseUrl)/api/v1/engage/sdk/testInvocation/event" }

    private static func normalizeRoot(_ rootUrl: String) throws -> String {
        let candidate = rootUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: candidate),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DigiaTestKit.Error.invalidRootUrl(rootUrl)
        }
        let scheme = components.scheme?.lowercased()
        let schemeDelimiter = "://"
        guard let range = candidate.range(of: schemeDelimiter) else {
            throw DigiaTestKit.Error.invalidRootUrl(rootUrl)
        }
        let suffix = String(candidate[range.upperBound...])
        let authority = suffix.hasSuffix("/") ? String(suffix.dropLast()) : suffix

        guard !candidate.isEmpty,
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil || components.user?.isEmpty == true,
              components.password == nil,
              !authority.isEmpty,
              !authority.contains("/"),
              !authority.contains("\\"),
              !authority.contains("@"),
              !authority.hasSuffix(":"),
              !suffix.contains("?"),
              !suffix.contains("#"),
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil,
              components.port == nil || (components.port! >= 1 && components.port! <= 65535)
        else {
            throw DigiaTestKit.Error.invalidRootUrl(rootUrl)
        }

        let portPart = components.port != nil ? ":\(components.port!)" : ""
        return "\(scheme!)://\(host)\(portPart)"
    }
}
