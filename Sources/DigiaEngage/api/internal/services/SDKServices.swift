import Foundation

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
    var sessionManager: SessionManager
    var sessionReporter: SessionReporter?
    let deviceIdProvider: DeviceIdProvider
    var analyticsService: AnalyticsService?
    var frequencyManager: FrequencyManager?
    let submissionReporter: SubmissionReporter

    init(
        config: DigiaConfig,
        storage: LocalStorage,
        networkClient: any NetworkClient
    ) {
        self.storage = storage
        let identityManager = IdentityManager(storage: storage.scoped("identity"))
        self.identityManager = identityManager
        self.sessionManager = SessionManager(
            storage: storage,
            timeoutMs: Int64(config.analyticsConfig.sessionTimeoutMs)
        )
        let deviceIdProvider = DefaultDeviceIdProvider(identityManager: identityManager)
        self.deviceIdProvider = deviceIdProvider
        self.submissionReporter = SubmissionReporter(
            identityManager: identityManager,
            networkClient: networkClient
        )
    }

    /// Stops everything this container started. Called before it is dropped.
    func tearDown() {
        analyticsService?.clear()
    }
}
