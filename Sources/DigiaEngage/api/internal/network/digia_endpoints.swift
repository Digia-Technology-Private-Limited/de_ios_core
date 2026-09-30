import Foundation

enum DigiaEndpointRegistry {
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

    static func useMockServer(_ rootURL: String, allowInRelease: Bool) throws {
        guard !_initialized else {
            throw DigiaTestKitError.alreadyInitialized
        }
        guard DigiaDebugDetection.isDebugBuild() || allowInRelease else {
            throw DigiaTestKitError.unavailableInRelease
        }
        _testRoot = try normalizeRoot(rootURL)
    }

    /// Resets all endpoint and test state to defaults. Use in tests only.
    static func resetForTest() {
        _environmentRoot = production
        _testRoot = nil
        _initialized = false
    }

    static var rootURL: String { _testRoot ?? _environmentRoot }
    static var baseUrl: String { rootURL }

    static var campaigns: String { "\(baseUrl)/api/v1/engage/sdk/getCampaigns" }
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
        guard let schemeDelimiter = candidate.range(of: "://") else {
            throw DigiaTestKit.Error.invalidRootUrl(rootUrl)
        }
        guard let url = URL(string: candidate),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DigiaTestKit.Error.invalidRootUrl(rootUrl)
        }
        let scheme = components.scheme?.lowercased()
        let suffix = String(candidate[schemeDelimiter.upperBound...])
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

enum DigiaEndpoints {
    static var isInitialized: Bool { DigiaEndpointRegistry.isInitialized }

    static func configure(_ config: DigiaConfig) {
        DigiaEndpointRegistry.configure(config)
    }

    static func setTestRoot(_ rootUrl: String) throws {
        try DigiaEndpointRegistry.setTestRoot(rootUrl)
    }

    static func useMockServer(_ rootURL: String, allowInRelease: Bool) throws {
        try DigiaEndpointRegistry.useMockServer(rootURL, allowInRelease: allowInRelease)
    }

    /// Resets to the production default. Use in tests only.
    static func resetForTest() {
        DigiaEndpointRegistry.resetForTest()
    }

    static var baseUrl: String { DigiaEndpointRegistry.baseUrl }
    static var rootURL: String { DigiaEndpointRegistry.rootURL }

    static var campaigns: String { DigiaEndpointRegistry.campaigns }
    static var campaignBundle: String { DigiaEndpointRegistry.campaignBundle }
    static var track: String { DigiaEndpointRegistry.track }
    static var session: String { DigiaEndpointRegistry.session }
    static var submission: String { DigiaEndpointRegistry.submission }
    static var recordComponents: String { DigiaEndpointRegistry.recordComponents }
    static var recordPageCapture: String { DigiaEndpointRegistry.recordPageCapture }
    static var liveTestConnect: String { DigiaEndpointRegistry.liveTestConnect }
    static var liveTestAck: String { DigiaEndpointRegistry.liveTestAck }
    static var liveTestEvent: String { DigiaEndpointRegistry.liveTestEvent }
}
