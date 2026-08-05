import Foundation

enum DigiaEndpointRegistry {
    private static let production = "https://app.digia.tech"
    private static let sandbox = "https://dev.digia.tech"

    nonisolated(unsafe) private static var environmentRoot = production
    nonisolated(unsafe) private static var testRoot: String?
    nonisolated(unsafe) private static var initialized = false

    static func configure(_ config: DigiaConfig) {
        environmentRoot = config.environment == .sandbox ? sandbox : production
        initialized = true
    }

    static func useMockServer(_ rootURL: String, allowInRelease: Bool) throws {
        guard !initialized else {
            throw DigiaTestKitError.alreadyInitialized
        }
        guard DigiaDebugDetection.isDebugBuild() || allowInRelease else {
            throw DigiaTestKitError.unavailableInRelease
        }

        let candidate = rootURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeDelimiter = candidate.range(of: "://") else {
            throw DigiaTestKitError.invalidMockServerURL(rootURL)
        }
        let suffix = String(candidate[schemeDelimiter.upperBound...])
        let authority = suffix.hasSuffix("/") ? String(suffix.dropLast()) : suffix
        guard
            let components = URLComponents(string: candidate),
            components.url != nil,
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.isEmpty,
            !authority.isEmpty,
            !authority.contains("/"),
            !authority.contains("\\"),
            !authority.contains("@"),
            !authority.hasSuffix(":"),
            !suffix.contains("?"),
            !suffix.contains("#"),
            components.user == nil,
            components.password == nil,
            components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
            components.percentEncodedQuery == nil,
            components.percentEncodedFragment == nil,
            components.port == nil || (1...65_535).contains(components.port!)
        else {
            throw DigiaTestKitError.invalidMockServerURL(rootURL)
        }

        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = components.port
        guard let normalizedURL = origin.url else {
            throw DigiaTestKitError.invalidMockServerURL(rootURL)
        }
        testRoot = normalizedURL.absoluteString.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
    }

    static var rootURL: String {
        testRoot ?? environmentRoot
    }

    /// Resets all endpoint state. Use in tests only.
    static func resetForTest() {
        environmentRoot = production
        testRoot = nil
        initialized = false
    }
}

enum DigiaEndpoints {
    static func configure(_ config: DigiaConfig) {
        DigiaEndpointRegistry.configure(config)
    }

    /// Resets to the production default. Use in tests only.
    static func resetForTest() {
        DigiaEndpointRegistry.resetForTest()
    }

    private static var baseURL: String { DigiaEndpointRegistry.rootURL }

    static var campaigns: String { "\(baseURL)/api/v1/engage/sdk/getCampaigns" }
    static var track: String { "\(baseURL)/api/v1/engage/sdk/track" }
    static var session: String { "\(baseURL)/api/v1/engage/sdk/session" }
    static var submission: String { "\(baseURL)/api/v1/engage/sdk/recordSubmission" }
    static var recordComponents: String { "\(baseURL)/api/v1/engage/sdk/recordComponents" }
    static var liveTestConnect: String { "\(baseURL)/api/v1/engage/sdk/live/connect" }
    static var liveTestAck: String { "\(baseURL)/api/v1/engage/sdk/testInvocation/ack" }
}
