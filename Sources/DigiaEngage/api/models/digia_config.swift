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
    /// Whether the floating Digia debug bubble is shown by default in
    /// debug-eligible builds. When `false` the bubble is hidden by default, but
    /// the debug settings screen stays reachable via the debug-settings deep
    /// link, from which the bubble can be re-enabled. A per-device toggle
    /// flipped in debug settings overrides this default once set. Has no effect
    /// in release/App-Store builds, where debug tools never show.
    ///
    /// Named `showDebugTools` (not `showsDebugTools`) for cross-stack uniformity
    /// with the Android/Flutter/RN SDKs.
    public let showDebugTools: Bool

    public init(
        apiKey: String,
        logLevel: DigiaLogLevel = .error,
        environment: DigiaEnvironment = .production,
        fontFamily: String? = nil,
        themeMode: DigiaThemeMode = .auto,
        analyticsConfig: AnalyticsConfig = AnalyticsConfig(),
        wrapperBinding: String? = nil,
        wrapperVersion: String? = nil,
        actionHandlers: DigiaActionHandlers = DigiaActionHandlers(),
        showDebugTools: Bool = true
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
        self.showDebugTools = showDebugTools
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
            && lhs.showDebugTools == rhs.showDebugTools
    }
}
