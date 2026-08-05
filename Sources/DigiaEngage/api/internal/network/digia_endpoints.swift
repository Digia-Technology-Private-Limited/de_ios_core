import Foundation

enum DigiaEndpointRegistry {
    private static let production = "https://app.digia.tech"
    private static let sandbox = "https://dev.digia.tech"

    nonisolated(unsafe) private static var environmentRoot = production
    nonisolated(unsafe) private static var testRoot: String?

    static func configure(_ config: DigiaConfig) {
        environmentRoot = config.environment == .sandbox ? sandbox : production
    }

    static func useMockServer(_ rootURL: String) throws {
        guard let parsedURL = URL(string: rootURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DigiaTestKitError.invalidMockServerURL(rootURL)
        }
        guard
            let scheme = parsedURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            parsedURL.host?.isEmpty == false
        else {
            throw DigiaTestKitError.invalidMockServerURL(rootURL)
        }
        testRoot = parsedURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func clearMockServer() {
        testRoot = nil
    }

    static var rootURL: String {
        testRoot ?? environmentRoot
    }

    /// Resets all endpoint state. Use in tests only.
    static func resetForTest(_ rootURL: String? = nil) {
        environmentRoot = (rootURL ?? production).trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        testRoot = nil
    }
}

enum DigiaEndpoints {
    static func configure(_ config: DigiaConfig) {
        DigiaEndpointRegistry.configure(config)
    }

    /// Resets to production default, or `baseURL`. Use in tests only.
    static func resetForTest(_ baseURL: String? = nil) {
        DigiaEndpointRegistry.resetForTest(baseURL)
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
