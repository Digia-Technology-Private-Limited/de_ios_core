import Foundation

/// How much the SDK prints. The *threshold* a host app configures; one line's
/// own loudness is `DigiaLogSeverity`, which is internal.
///
/// The three new values are **appended**, not inserted in severity order, so no
/// shipped value's position moves — and nothing may compare these by ordinal.
/// The one comparison in the SDK goes through an explicit severity mapping in
/// `DigiaLogger`.
public enum DigiaLogLevel: Sendable, Equatable {
    /// No logs emitted.
    case none

    /// The SDK could not do the thing: a campaign dropped, an action failed, an
    /// invariant violated. The quietest level that still reports failures.
    case error

    /// Everything. The original name for what is now ``debug``, and permanently
    /// valid — host apps have shipped with it.
    case verbose

    /// Degraded but recovered: a field fell back to a default, a retry
    /// succeeded. Adds to ``error``.
    case warn

    /// Lifecycle milestones: init complete, N campaigns loaded, trigger
    /// received. Adds to ``warn``.
    case info

    /// Per-node, per-frame, per-request detail. Adds to ``info``.
    case debug

    /// Let the SDK choose: loud while the host app is a debug build, quiet in
    /// release. **The default**, and never a value anything reads back —
    /// ``DigiaConfig/init(apiKey:logLevel:environment:fontFamily:themeMode:analyticsConfig:wrapperBinding:wrapperVersion:actionHandlers:)``
    /// resolves it at construction, so ``DigiaConfig/logLevel`` is never this.
    ///
    /// The developer most likely to need these logs is the one integrating
    /// Engage for the first time — and the one least likely to have read the
    /// page that says to turn them up.
    ///
    /// platform note: the diagnostics spec says this parameter takes *null*
    /// for auto, and Dart and Kotlin do exactly that. Swift cannot: with a
    /// `DigiaLogLevel?` parameter, `logLevel: .none` resolves to
    /// `Optional.none` rather than ``DigiaLogLevel/none``, so every shipped app
    /// that silenced the SDK would silently become debug-loud. A sentinel case
    /// keeps `.none` meaning none.
    case auto

    /// What ``auto`` means in this process.
    ///
    /// platform note: Dart reads `kReleaseMode`. iOS cannot use `#if DEBUG` —
    /// `DigiaEngage` ships to most consumers as a prebuilt xcframework compiled
    /// with Digia's own build config, so that flag would report Digia's build
    /// and not the host's. ``DigiaDebugDetection`` reads the host bundle
    /// instead, which is also what gates the debug screen.
    static var resolvedAuto: DigiaLogLevel { isHostDebugBuild ? .debug : .error }
}

/// Resolved once per process: parsing the host's embedded provisioning profile
/// is not something to repeat on every log call.
private let isHostDebugBuild = DigiaDebugDetection.isDebugBuild()

public enum DigiaEnvironment: Sendable, Equatable {
    case production
    case sandbox
}

public enum DigiaThemeMode: String, Sendable, Equatable {
    case auto, light, dark
}

public struct DigiaConfig: Sendable {
    public let apiKey: String

    /// The resolved verbosity threshold — never nil, even when the app passed
    /// nothing. See ``isLogLevelExplicit``.
    public let logLevel: DigiaLogLevel

    /// Whether ``logLevel`` came from this app or from ``DigiaLogLevel/auto``.
    ///
    /// The init banner prints it, and it is the whole answer to a "nothing
    /// shows up" ticket: `auto` resolves to `debug` outside release and an app
    /// may pass `debug` too, so the resolved value alone cannot say which.
    public let isLogLevelExplicit: Bool
    public let environment: DigiaEnvironment
    /// Optional global font family applied to all Digia-rendered text.
    /// Must match a font family registered by the host app.
    public let fontFamily: String?
    public let themeMode: DigiaThemeMode
    public let analyticsConfig: AnalyticsConfig
    public let wrapperBinding: String?
    public let wrapperVersion: String?
    public let actionHandlers: DigiaActionHandlers

    public init(
        apiKey: String,
        logLevel: DigiaLogLevel = .auto,
        environment: DigiaEnvironment = .production,
        fontFamily: String? = nil,
        themeMode: DigiaThemeMode = .auto,
        analyticsConfig: AnalyticsConfig = AnalyticsConfig(),
        wrapperBinding: String? = nil,
        wrapperVersion: String? = nil,
        actionHandlers: DigiaActionHandlers = DigiaActionHandlers()
    ) {
        self.apiKey = apiKey
        // Resolved here, so nothing reading `config.logLevel` ever has to
        // handle the sentinel — and so the banner can say whether the app chose
        // the level or we did.
        self.logLevel = logLevel == .auto ? .resolvedAuto : logLevel
        self.isLogLevelExplicit = logLevel != .auto
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
