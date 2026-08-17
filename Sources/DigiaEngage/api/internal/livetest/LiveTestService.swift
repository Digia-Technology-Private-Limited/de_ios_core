import Foundation
import Combine
import UIKit

/// Debug-only coordinator that keeps this SDK instance visible to the Engage
/// dashboard as a live-test target, and routes incoming `campaign_test` events
/// back to `SDKInstance` for rendering.
@MainActor
final class LiveTestService: ObservableObject {
    private static let keyEnabled = "digia_live_testing_enabled"
    private static let keyDeviceName = "digia_live_testing_device_name"

    let ackReporter: LiveTestAckReporter

    @Published private(set) var isEnabled = false
    @Published private(set) var connectionState: LiveTestConnectionState = .disconnected
    @Published private(set) var deviceName: String?
    @Published private(set) var deviceId: String?

    private let defaults: UserDefaults
    private var client: LiveTestSSEClient?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var isDebugBuildFlag = false

    init(
        ackReporter: LiveTestAckReporter = LiveTestAckReporter(),
        defaults: UserDefaults = .standard
    ) {
        self.ackReporter = ackReporter
        self.defaults = defaults
    }

    func configure(
        config: DigiaConfig,
        deviceId: String,
        isDebugBuild: Bool,
        onCampaignTest: @escaping (LiveTestInvocation) -> Void
    ) {
        stop()
        isDebugBuildFlag = isDebugBuild
        self.deviceId = deviceId
        guard isDebugBuild else { return }

        isEnabled = defaults.bool(forKey: Self.keyEnabled)
        deviceName = Self.normalizedName(defaults.string(forKey: Self.keyDeviceName))
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

    func setEnabled(_ enabled: Bool) {
        guard isDebugBuildFlag || !enabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.keyEnabled)
        if enabled { client?.start() } else { client?.stop() }
    }

    func setDeviceName(_ value: String) {
        let name = Self.normalizedName(value)
        guard name != deviceName else { return }
        deviceName = name
        if let name {
            defaults.set(name, forKey: Self.keyDeviceName)
        } else {
            defaults.removeObject(forKey: Self.keyDeviceName)
        }
        if isEnabled {
            client?.stop()
            client?.start()
        }
    }

    func stop() {
        client?.stop()
        if let obs = backgroundObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = foregroundObserver { NotificationCenter.default.removeObserver(obs) }
        backgroundObserver = nil
        foregroundObserver = nil
        connectionState = .disconnected
    }

    private static func normalizedName(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }
}
