import Foundation
import DigiaMediaCache

private let log = DigiaLogger("analytics")

/// The services that only exist once the SDK is initialized.
///
/// Built once, by `SDKInstance.initialize(_:)`, after `LocalStorageMigrator`
/// has run and the config is known — never before (D1). Collaborators that are
/// needed before `initialize()` (the campaign store, component registry, live
/// test service and network client) are owned by `SDKInstance` instead.
@MainActor
final class SDKServices {
    let identityManager: IdentityManager
    let sessionManager: SessionManager
    let sessionReporter: SessionReporter
    /// The session-and-identity rules; already attached by `init`.
    let sessionIdentityWiring: SessionIdentityWiring
    let analyticsService: AnalyticsService?
    let frequencyManager: FrequencyManager
    let submissionReporter: SubmissionReporter
    let requestHeaders: [String: String]
    /// The one video player pool for this SDK instance (D3): every `MediaVideo`
    /// with a keep-alive key borrows from here. Released in `tearDown`, which
    /// also covers SDK re-init — `initialize()` never replaces a live
    /// `SDKServices`, it early-returns when one exists, so there is no
    /// reassign-without-release path.
    let videoPlayerPool: VideoPlayerPool
    /// Where the story viewer reads the D10 slow-network flag from.
    let slowNetworkSource: any SlowNetworkSource

    init(
        config: DigiaConfig,
        storage: LocalStorage,
        networkClient: any NetworkClient,
        clock: @escaping () -> Int64 = SessionManager.systemClock,
        analyticsQueue: any AnalyticsQueueProtocol,
        networkMonitor: any NetworkMonitor = AlwaysOnlineNetworkMonitor(),
        playerFactory: any PlayerFactory = DefaultPlayerFactory(),
        maxPoolSize: Int? = nil,
        slowNetworkSource: (any SlowNetworkSource)? = nil
    ) {
        let identityManager = IdentityManager(
            storage: storage.scoped("identity"),
            idGenerator: IdentityManager.systemIdGenerator
        )
        self.identityManager = identityManager
        let sessionManager = SessionManager(
            storage: storage.scoped("session"),
            timeoutMs: Int64(config.analyticsConfig.sessionTimeoutMs),
            clock: clock,
            observeLifecycle: true
        )
        self.sessionManager = sessionManager
        let requestHeaders = SDKRequestHeaders.make(config: config, deviceId: identityManager.deviceId)
        self.requestHeaders = requestHeaders
        let staticContext = AnalyticsService.buildStaticContext(
            wrapperBinding: config.wrapperBinding,
            wrapperVersion: config.wrapperVersion
        )
        let sessionReporter = SessionReporter(
            sessionId: { [weak sessionManager] in sessionManager?.sessionId ?? "" },
            anonymousId: { [weak identityManager] in identityManager?.deviceId ?? "" },
            userId: { [weak identityManager] in identityManager?.userId },
            context: staticContext,
            networkClient: networkClient,
            storage: storage.scoped("session")
        )
        self.sessionReporter = sessionReporter
        let sessionIdentityWiring = SessionIdentityWiring(
            identityManager: identityManager,
            sessionManager: sessionManager,
            sessionReporter: config.analyticsConfig.enabled ? sessionReporter : nil
        )
        sessionIdentityWiring.attach()
        self.sessionIdentityWiring = sessionIdentityWiring
        // Frequency capping reads the same sessionId the backend sees, so
        // `session` windows track the reported session.
        self.frequencyManager = FrequencyManager(
            storage: storage.scoped("frequency"),
            sessionIdProvider: { [weak sessionManager] in sessionManager?.sessionId }
        )
        let ac = config.analyticsConfig
        if ac.enabled {
            let analyticsConfig = DigiaEndpoints.isTestMode
                ? AnalyticsConfig(
                    enabled: ac.enabled,
                    flushIntervalMs: 100,
                    flushBatchSize: 1,
                    maxBatchSize: ac.maxBatchSize,
                    queueMaxEvents: ac.queueMaxEvents,
                    sessionTimeoutMs: ac.sessionTimeoutMs
                )
                : ac
            log.d("Analytics enabled (batchSize=\(analyticsConfig.flushBatchSize), interval=\(analyticsConfig.flushIntervalMs)ms)")
            self.analyticsService = AnalyticsService(
                config: analyticsConfig,
                identityManager: identityManager,
                sessionManager: sessionManager,
                queue: analyticsQueue,
                staticContext: staticContext,
                networkClient: networkClient,
                networkMonitor: networkMonitor
            )
        } else {
            log.i("Analytics disabled in DigiaConfig — no events will be captured")
            self.analyticsService = nil
        }
        self.submissionReporter = SubmissionReporter(
            sessionIdProvider: { [weak sessionManager] in sessionManager?.sessionId },
            networkClient: networkClient
        )
        let deviceClass = deviceClassOf()
        self.videoPlayerPool = VideoPlayerPool(
            factory: playerFactory,
            maxPlayers: maxPoolSize ?? maxPoolPlayers(deviceClass: deviceClass)
        )
        self.slowNetworkSource = slowNetworkSource ?? PathSlowNetworkSource()
    }

    /// Stops everything this container started. Called before it is dropped.
    func tearDown() {
        videoPlayerPool.release()
        analyticsService?.clear()
    }
}

/// The SDK wiring for the media layer's ambient services (D17): the default
/// `MediaServices` fronts this container's pool plus the process-wide shared
/// store, image stack and health sink, so hosts that provide nothing explicit
/// behave exactly as before. The closures read `SDKInstance.shared` lazily —
/// at borrow time, not at construction — so the environment default never
/// captures a torn-down graph. `internal/media/` never names `SDKInstance`;
/// this extension is the only place the two meet.
extension MediaServices {
    static func sdkDefault() -> MediaServices {
        MediaServices(
            pool: { MainActor.assumeIsolated { SDKInstance.shared.services?.videoPlayerPool } },
            store: { MediaRangeCacheStore.shared() },
            imageLoader: nil,
            reportHealth: { campaignKey, kind, cause in
                reportMediaLoadFailed(kind, cause: cause, campaignKey: campaignKey)
            }
        )
    }
}
