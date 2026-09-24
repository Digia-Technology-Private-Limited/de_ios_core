import Foundation
import Combine
import UIKit

/// Debug-only coordinator that keeps this SDK instance visible to the Engage
/// dashboard as a live-test target and routes incoming campaigns for rendering.
@MainActor
final class LiveTestService: ObservableObject {
    private static let enabledKey = "enabled"
    private static let deviceNameKey = "device_name"

    let ackReporter: LiveTestAckReporter
    private let storage: LocalStorage

    @Published private(set) var isEnabled = false
    @Published private(set) var connectionState: LiveTestConnectionState = .disconnected
    @Published private(set) var deviceName: String?
    private(set) var deviceId: String?

    private var client: LiveTestSSEClient?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var isDebugBuildFlag = false
    private let networkClient: any NetworkClient

    init(
        storage: LocalStorage,
        ackReporter: LiveTestAckReporter? = nil,
        networkClient: any NetworkClient
    ) {
        self.networkClient = networkClient
        self.storage = storage
        self.ackReporter = ackReporter ?? LiveTestAckReporter(networkClient: networkClient)
        self.deviceName = Self.normalizeDeviceName(storage.string(forKey: Self.deviceNameKey))
    }

    convenience init(
        defaults: UserDefaults,
        ackReporter: LiveTestAckReporter? = nil,
        networkClient: any NetworkClient
    ) {
        self.init(
            storage: UserDefaultsLocalStorage(defaults: defaults).scoped("live_test"),
            ackReporter: ackReporter,
            networkClient: networkClient
        )
    }

    func configure(
        config: DigiaConfig,
        requestHeaders: [String: String],
        deviceId: String,
        isDebugBuild: Bool,
        onCampaignTest: @escaping (LiveTestInvocation) -> Void
    ) {
        stop()
        isDebugBuildFlag = isDebugBuild
        self.deviceId = deviceId
        guard isDebugBuild else { return }

        isEnabled = storage.bool(forKey: Self.enabledKey)
        ackReporter.configure(config: config, deviceId: deviceId)
        let sseClient = LiveTestSSEClient(
            config: { config },
            deviceId: { deviceId },
            requestHeaders: requestHeaders,
            deviceName: { [weak self] in self?.deviceName },
            onEvent: { event in
                if case .campaignTest(let invocation) = event { onCampaignTest(invocation) }
            },
            onConnectionStateChanged: { [weak self] state in self?.connectionState = state },
            networkClient: networkClient
        )
        client = sseClient
        if isEnabled { sseClient.start() }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.client?.stop() }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isDebugBuildFlag, self.isEnabled else { return }
                self.client?.start()
            }
        }
    }

    /// Persists the preference unconditionally, even before `configure()` has
    /// run — the debug settings screen already gates its own visibility on a
    /// debug build, so a second guard here only meant a toggle flipped before
    /// the SDK reached ready (a real RN race, not a hypothetical) silently
    /// failed to persist. The stream itself starts only when `client` exists,
    /// i.e. once `configure()` has actually wired one up.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        storage.set(enabled, forKey: Self.enabledKey)
        if enabled { client?.start() } else { client?.stop() }
    }

    func setDeviceName(_ value: String) {
        let updatedName = Self.normalizeDeviceName(value)
        guard updatedName != deviceName else { return }

        deviceName = updatedName
        if let updatedName {
            storage.set(updatedName, forKey: Self.deviceNameKey)
        } else {
            storage.removeObject(forKey: Self.deviceNameKey)
        }

        guard client?.isRunning == true else { return }
        client?.stop()
        client?.start()
    }

    func stop() {
        client?.stop()
        if let obs = backgroundObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = foregroundObserver { NotificationCenter.default.removeObserver(obs) }
        backgroundObserver = nil
        foregroundObserver = nil
        connectionState = .disconnected
    }

    private static func normalizeDeviceName(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
