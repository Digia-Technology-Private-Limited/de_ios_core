import Foundation
import Combine
import UIKit

/// Debug-only coordinator that keeps this SDK instance visible to the Engage
/// dashboard as a live-test target, and routes incoming `campaign_test` events
/// back to `SDKInstance` for rendering. Active whenever the "Sync" toggle
/// (`ComponentRegistryService.isEnabled`) is on.
@MainActor
final class LiveTestService: ObservableObject {
    private static let deviceNameKey = "digia_live_testing_device_name"

    let ackReporter: LiveTestAckReporter
    private let defaults: UserDefaults

    @Published private(set) var connectionState: LiveTestConnectionState = .disconnected
    @Published private(set) var deviceName: String?

    private var client: LiveTestSSEClient?
    private var toggleCancellable: AnyCancellable?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var isDebugBuildFlag = false
    private var componentRegistry: ComponentRegistryService?

    init(
        defaults: UserDefaults = .standard,
        ackReporter: LiveTestAckReporter = LiveTestAckReporter()
    ) {
        self.defaults = defaults
        self.ackReporter = ackReporter
        self.deviceName = Self.normalizeDeviceName(defaults.string(forKey: Self.deviceNameKey))
    }

    func configure(
        config: DigiaConfig,
        deviceId: String,
        isDebugBuild: Bool,
        componentRegistry: ComponentRegistryService,
        onCampaignTest: @escaping (LiveTestInvocation) -> Void
    ) {
        stop()
        isDebugBuildFlag = isDebugBuild
        self.componentRegistry = componentRegistry
        guard isDebugBuild else { return }

        ackReporter.configure(config: config, deviceId: deviceId)
        let sseClient = LiveTestSSEClient(
            config: { config },
            deviceId: { deviceId },
            deviceName: { [weak self] in self?.deviceName },
            onEvent: { event in
                if case .campaignTest(let invocation) = event { onCampaignTest(invocation) }
            },
            onConnectionStateChanged: { [weak self] state in self?.connectionState = state }
        )
        client = sseClient

        toggleCancellable = componentRegistry.$isEnabled.sink { [weak sseClient] enabled in
            if enabled { sseClient?.start() } else { sseClient?.stop() }
        }

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
                guard let self, self.isDebugBuildFlag, self.componentRegistry?.isEnabled == true else { return }
                self.client?.start()
            }
        }
    }

    func setDeviceName(_ value: String) {
        let updatedName = Self.normalizeDeviceName(value)
        guard updatedName != deviceName else { return }

        deviceName = updatedName
        if let updatedName {
            defaults.set(updatedName, forKey: Self.deviceNameKey)
        } else {
            defaults.removeObject(forKey: Self.deviceNameKey)
        }

        guard client?.isRunning == true else { return }
        client?.stop()
        client?.start()
    }

    func stop() {
        toggleCancellable?.cancel()
        toggleCancellable = nil
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
