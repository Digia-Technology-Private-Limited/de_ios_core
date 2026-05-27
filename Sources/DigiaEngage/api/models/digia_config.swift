import Foundation

public enum DigiaLogLevel: Sendable, Equatable {
    case none
    case error
    case verbose
}

public enum DigiaEnvironment: Sendable, Equatable {
    case production
    case sandbox
}

public struct DigiaNetworkConfiguration: Sendable, Equatable {
    public let defaultHeaders: [String: String]
    public let timeout: Duration

    public init(
        defaultHeaders: [String: String] = [:],
        timeout: Duration = .seconds(30)
    ) {
        self.defaultHeaders = defaultHeaders
        self.timeout = timeout
    }
}

public struct DigiaDeveloperConfig: Sendable, Equatable {
    public let proxyURL: String?
    public let baseURL: String

    public init(
        proxyURL: String? = nil,
        baseURL: String = "https://app.digia.tech/api/v1"
    ) {
        self.proxyURL = proxyURL
        self.baseURL = baseURL
    }
}

public struct DigiaConfig: Sendable, Equatable {
    public let apiKey: String
    public let logLevel: DigiaLogLevel
    public let environment: DigiaEnvironment
    public let baseUrl: String?
    public let networkConfiguration: DigiaNetworkConfiguration?
    public let developerConfig: DigiaDeveloperConfig?

    public init(
        apiKey: String,
        logLevel: DigiaLogLevel = .error,
        environment: DigiaEnvironment = .production,
        baseUrl: String? = nil,
        networkConfiguration: DigiaNetworkConfiguration? = nil,
        developerConfig: DigiaDeveloperConfig? = nil
    ) {
        self.apiKey = apiKey
        self.logLevel = logLevel
        self.environment = environment
        self.baseUrl = baseUrl
        self.networkConfiguration = networkConfiguration
        self.developerConfig = developerConfig
    }
}
