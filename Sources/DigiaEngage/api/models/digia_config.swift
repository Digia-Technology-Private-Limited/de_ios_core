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

public struct DigiaConfig: Sendable {
    public let apiKey: String
    public let logLevel: DigiaLogLevel
    public let environment: DigiaEnvironment
    /// Optional global font family applied to all Digia-rendered text.
    /// Must match a font family registered by the host app.
    public let fontFamily: String?
    public let analyticsConfig: AnalyticsConfig
    public let wrapperBinding: String?
    public let wrapperVersion: String?
    public let actionHandlers: DigiaActionHandlers

    public init(
        apiKey: String,
        logLevel: DigiaLogLevel = .error,
        environment: DigiaEnvironment = .production,
        fontFamily: String? = nil,
        analyticsConfig: AnalyticsConfig = AnalyticsConfig(),
        wrapperBinding: String? = nil,
        wrapperVersion: String? = nil,
        actionHandlers: DigiaActionHandlers = DigiaActionHandlers()
    ) {
        self.apiKey = apiKey
        self.logLevel = logLevel
        self.environment = environment
        self.fontFamily = fontFamily
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
            && lhs.fontFamily == rhs.fontFamily
            && lhs.analyticsConfig == rhs.analyticsConfig
            && lhs.wrapperBinding == rhs.wrapperBinding
            && lhs.wrapperVersion == rhs.wrapperVersion
    }
}
