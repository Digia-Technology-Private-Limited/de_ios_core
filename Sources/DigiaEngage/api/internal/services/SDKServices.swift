import Foundation

private let log = DigiaLogger("analytics")

/// The services that only exist once the SDK is initialized.
///
/// Built once, by `SDKInstance.initialize(_:)`, after `LocalStorageMigrator`
/// has run and the config is known — never before (D1). Collaborators that are
/// needed before `initialize()` (the campaign store, component registry, live
/// test service and network client) are owned by `SDKInstance` instead.
@MainActor
final class SDKServices {
    let storage: LocalStorage
    let identityManager: IdentityManager
    let sessionManager: SessionManager
    let sessionReporter: SessionReporter
    let deviceIdProvider: DeviceIdProvider
    let analyticsService: AnalyticsService?
    let frequencyManager: FrequencyManager
    let submissionReporter: SubmissionReporter
    let requestHeaders: [String: String]

    init(
        config: DigiaConfig,
        storage: LocalStorage,
        networkClient: any NetworkClient
    ) {
        self.storage = storage
        let identityManager = IdentityManager(storage: storage.scoped("identity"))
        self.identityManager = identityManager
        let sessionManager = SessionManager(
            storage: storage.scoped("session"),
            timeoutMs: Int64(config.analyticsConfig.sessionTimeoutMs)
        )
        self.sessionManager = sessionManager
        // A new or cleared user starts a new session (D2), whatever the
        // analytics setting.
        identityManager.addUserChangedListener { [weak sessionManager] in
            sessionManager?.reset()
        }
        let requestHeaders = SDKRequestHeaders.make(config: config, deviceId: identityManager.deviceId)
        self.requestHeaders = requestHeaders
        let staticContext = AnalyticsService.buildStaticContext(
            wrapperBinding: config.wrapperBinding,
            wrapperVersion: config.wrapperVersion
        )
        let sessionReporter = SessionReporter(
            apiKey: config.apiKey,
            sessionId: { [weak sessionManager] in sessionManager?.sessionId ?? "" },
            anonymousId: { [weak identityManager] in identityManager?.deviceId ?? "" },
            userId: { [weak identityManager] in identityManager?.userId },
            context: staticContext,
            requestHeaders: requestHeaders,
            networkClient: networkClient,
            storage: storage.scoped("session")
        )
        self.sessionReporter = sessionReporter
        sessionManager.addRotationListener { [weak sessionReporter] in
            sessionReporter?.report()
        }
        // Frequency capping reads the same sessionId the backend sees, so
        // `session` windows track the reported session.
        self.frequencyManager = FrequencyManager(
            storage: storage.scoped("frequency"),
            sessionIdProvider: { [weak sessionManager] in sessionManager?.sessionId }
        )
        let ac = config.analyticsConfig
        if ac.enabled {
            log.d("Analytics enabled (batchSize=\(ac.flushBatchSize), interval=\(ac.flushIntervalMs)ms)")
            self.analyticsService = AnalyticsService(
                config: ac,
                apiKey: config.apiKey,
                identityManager: identityManager,
                sessionManager: sessionManager,
                queue: AnalyticsQueue(storage: storage.scoped("analytics")),
                staticContext: staticContext,
                networkClient: networkClient,
                requestHeaders: requestHeaders
            )
        } else {
            log.i("Analytics disabled in DigiaConfig — no events will be captured")
            self.analyticsService = nil
        }
        let deviceIdProvider = DefaultDeviceIdProvider(identityManager: identityManager)
        self.deviceIdProvider = deviceIdProvider
        self.submissionReporter = SubmissionReporter(
            identityManager: identityManager,
            sessionIdProvider: { [weak sessionManager] in sessionManager?.sessionId },
            networkClient: networkClient
        )
    }

    /// Stops everything this container started. Called before it is dropped.
    func tearDown() {
        analyticsService?.clear()
    }
}
