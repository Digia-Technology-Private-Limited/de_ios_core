import Foundation
import Combine
import UIKit

/// Debug-only coordinator that keeps this SDK instance visible to the Engage
/// dashboard as a live-test target, and routes incoming `campaign_test` events
/// back to `SDKInstance` for rendering.
///
/// Active whenever the "Sync" toggle (`ComponentRegistryService.isEnabled`) is
/// on — the same flag that already gates Engage Component Registry recording,
/// reused here rather than adding a second switch. Reacts to the toggle live
/// (opens/closes the stream immediately), unlike component-registry recording
/// itself, which currently needs a reload to take effect — a live presence
/// stream needs to reflect the toggle right away.
///
/// No-ops entirely outside a debug build (`configure`'s `isDebugBuild`
/// parameter) — same defense-in-depth posture as `ComponentRegistryService`.
///
/// Constructed once and held for `SDKInstance`'s lifetime (like
/// `ComponentRegistryService`) — `configure` can be called more than once
/// (e.g. `completeInitialization` re-running from the RN `populateCampaigns`
/// path), so it always tears down its previous wiring first rather than
/// accumulating a second Combine subscription/notification observer pair.
@MainActor
final class LiveTestService: ObservableObject {
    let ackReporter: LiveTestAckReporter

    @Published private(set) var connectionState: LiveTestConnectionState = .disconnected

    private var client: LiveTestSSEClient?
    private var toggleCancellable: AnyCancellable?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var isDebugBuildFlag = false
    private var componentRegistry: ComponentRegistryService?

    init(ackReporter: LiveTestAckReporter = LiveTestAckReporter()) {
        self.ackReporter = ackReporter
    }

    /// Called from `SDKInstance.completeInitialization`, immediately after
    /// `componentRegistry.configure(...)`.
    func configure(
        config: DigiaConfig,
        deviceId: String,
        isDebugBuild: Bool,
        componentRegistry: ComponentRegistryService,
        onCampaignTest: @escaping (LiveTestInvocation) -> Void
    ) {
        stop() // tear down any previous wiring before re-wiring
        isDebugBuildFlag = isDebugBuild
        self.componentRegistry = componentRegistry
        guard isDebugBuild else { return }

        ackReporter.configure(config: config, deviceId: deviceId)
        let sseClient = LiveTestSSEClient(
            config: { config },
            deviceId: { deviceId },
            onEvent: { event in
                if case .campaignTest(let invocation) = event { onCampaignTest(invocation) }
            },
            onConnectionStateChanged: { [weak self] state in self?.connectionState = state }
        )
        client = sseClient

        toggleCancellable = componentRegistry.$isEnabled.sink { [weak sseClient] enabled in
            if enabled { sseClient?.start() } else { sseClient?.stop() }
        }

        // So a backgrounded device doesn't hold a stale presence lease between
        // heartbeats.
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

    /// Tears this instance down: cancels the toggle subscription, stops the
    /// SSE client, and removes the lifecycle observers. Called at the start of
    /// every `configure` and from `SDKInstance.resetForTesting`.
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
}
