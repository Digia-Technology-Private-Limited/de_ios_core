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

public enum DigiaThemeMode: String, Sendable, Equatable {
    case auto, light, dark
}

public struct DigiaConfig: Sendable {
    public let apiKey: String
    public let logLevel: DigiaLogLevel
    public let environment: DigiaEnvironment
    /// Optional global font family applied to all Digia-rendered text.
    /// Must match a font family registered by the host app.
    public let fontFamily: String?
    public let themeMode: DigiaThemeMode
    public let analyticsConfig: AnalyticsConfig
    public let wrapperBinding: String?
    public let wrapperVersion: String?
    public let actionHandlers: DigiaActionHandlers

    /// Composite SDK identity sent to Digia services and analytics.
    public var sdkVersionDescriptor: String {
        var parts = ["s=1", "b=\(wrapperBinding ?? "native")", "p=ios"]
        if let wrapperVersion, !wrapperVersion.isEmpty { parts.append("w=\(wrapperVersion)") }
        parts.append("c=\(DigiaSdkVersion.value)")
        return parts.joined(separator: "|")
    }

    public init(
        apiKey: String,
        logLevel: DigiaLogLevel = .error,
        environment: DigiaEnvironment = .production,
        fontFamily: String? = nil,
        themeMode: DigiaThemeMode = .auto,
        analyticsConfig: AnalyticsConfig = AnalyticsConfig(),
        wrapperBinding: String? = nil,
        wrapperVersion: String? = nil,
        actionHandlers: DigiaActionHandlers = DigiaActionHandlers()
    ) {
        self.apiKey = apiKey
        self.logLevel = logLevel
        self.environment = environment
        self.fontFamily = fontFamily
        self.themeMode = themeMode
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
            && lhs.themeMode == rhs.themeMode
            && lhs.analyticsConfig == rhs.analyticsConfig
            && lhs.wrapperBinding == rhs.wrapperBinding
            && lhs.wrapperVersion == rhs.wrapperVersion
    }
}
