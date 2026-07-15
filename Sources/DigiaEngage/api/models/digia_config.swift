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
    /// Seconds. `Duration` (iOS 16+) would raise this type's floor for every
    /// consumer of `DigiaConfig`; `TimeInterval` keeps it representable down to
    /// the SDK's iOS 15 minimum.
    public let timeout: TimeInterval

    public init(
        defaultHeaders: [String: String] = [:],
        timeout: TimeInterval = 30
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

public struct DigiaConfig: Sendable {
    public let apiKey: String
    public let logLevel: DigiaLogLevel
    public let environment: DigiaEnvironment
    public let networkConfiguration: DigiaNetworkConfiguration?
    public let developerConfig: DigiaDeveloperConfig?
    /// Optional global font family applied to all Digia-rendered text.
    /// Resolved via `Font.custom` / `UIFont(name:)`, so it must match a font
    /// registered with the app (e.g. a bundled custom font's PostScript name).
    public let fontFamily: String?
    /// Optional exact face names keyed by numeric weight. Primarily used by wrappers
    /// that own a runtime font registry; native callers can continue using `fontFamily`.
    public let fontFamilyAliases: [Int: String]
    public let analyticsConfig: AnalyticsConfig
    public let wrapperBinding: String?
    public let wrapperVersion: String?
    public let actionHandlers: DigiaActionHandlers

    public init(
        apiKey: String,
        logLevel: DigiaLogLevel = .error,
        environment: DigiaEnvironment = .production,
        networkConfiguration: DigiaNetworkConfiguration? = nil,
        developerConfig: DigiaDeveloperConfig? = nil,
        fontFamily: String? = nil,
        fontFamilyAliases: [Int: String] = [:],
        analyticsConfig: AnalyticsConfig = AnalyticsConfig(),
        wrapperBinding: String? = nil,
        wrapperVersion: String? = nil,
        actionHandlers: DigiaActionHandlers = DigiaActionHandlers()
    ) {
        self.apiKey = apiKey
        self.logLevel = logLevel
        self.environment = environment
        self.networkConfiguration = networkConfiguration
        self.developerConfig = developerConfig
        self.fontFamily = fontFamily
        self.fontFamilyAliases = fontFamilyAliases
        self.analyticsConfig = analyticsConfig
        self.wrapperBinding = wrapperBinding
        self.wrapperVersion = wrapperVersion
        self.actionHandlers = actionHandlers
    }
}

extension DigiaConfig: Equatable {
    public static func == (lhs: DigiaConfig, rhs: DigiaConfig) -> Bool {
        lhs.apiKey == rhs.apiKey
            && lhs.logLevel == rhs.logLevel
            && lhs.environment == rhs.environment
            && lhs.networkConfiguration == rhs.networkConfiguration
            && lhs.developerConfig == rhs.developerConfig
            && lhs.fontFamily == rhs.fontFamily
            && lhs.fontFamilyAliases == rhs.fontFamilyAliases
            && lhs.analyticsConfig == rhs.analyticsConfig
            && lhs.wrapperBinding == rhs.wrapperBinding
            && lhs.wrapperVersion == rhs.wrapperVersion
    }
}
