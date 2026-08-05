import Foundation
import Combine

/// Reports pages/anchors/slots seen at runtime to the Engage Component
/// Registry (`POST .../recordComponents`), so a PM can curate them on the
/// dashboard instead of typing keys by hand.
///
/// Only active when `isEnabled` (the debug-only "recording mode" toggle) and
/// on a debug build — re-checked here as defense in depth even though every
/// caller already gates on it.
///
/// Fire-and-forget like `SurveySubmissionReporter`, not the retrying
/// `AnalyticsService` queue — a dropped ping self-heals next time the key is
/// seen. No batching: recording is manual and low-volume, so it's unneeded
/// complexity.
@MainActor
final class ComponentRegistryService: ObservableObject {
    private static let keyEnabled = "digia_component_registry_recording_enabled"

    private let defaults: UserDefaults
    private let sender: any AnalyticsSender

    private var config: DigiaConfig?
    private var deviceId: String?
    private var isDebugBuildFlag = false
    private var capturePairingToken: String?

    /// Kept in sync across `RecordingBadgeView` and the debug/session screens.
    @Published private(set) var isEnabled = false
    var isCapturePaired: Bool { capturePairingToken != nil }

    /// Every distinct key recorded this process, in first-seen order — what
    /// `DigiaRecordedSessionScreen` lists. Not persisted, see `seen` below.
    @Published private(set) var recordedThisSession: [RecordedComponentEntry] = []

    /// `"<type>:<key>:<screenName>"` already sent this process. Not persisted —
    /// the backend upsert is idempotent, so resending on a fresh process is
    /// harmless. Without this, a recycled view (e.g. a list-cell anchor) could
    /// refire the same key repeatedly.
    private var seen = Set<String>()

    private let debugOverlay: DigiaDebugOverlayController?

    init(
        defaults: UserDefaults = .standard,
        sender: any AnalyticsSender = URLSessionAnalyticsSender(),
        debugOverlay: DigiaDebugOverlayController? = nil
    ) {
        self.defaults = defaults
        self.sender = sender
        self.debugOverlay = debugOverlay
    }

    /// Called once from `SDKInstance.completeInitialization` after the device id
    /// is known.
    func configure(config: DigiaConfig, deviceId: String, isDebugBuild: Bool) {
        self.config = config
        self.deviceId = deviceId
        self.isDebugBuildFlag = isDebugBuild
        self.isEnabled = defaults.bool(forKey: Self.keyEnabled)
    }

    /// Flips the persisted recording toggle. Also shows the bubble if hidden
    /// (so it's visible when recording starts) — but turning recording off
    /// doesn't hide it back; bubble visibility is otherwise independent.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.keyEnabled)
        if enabled, let debugOverlay, !debugOverlay.isVisible {
            debugOverlay.setVisible(true)
        }
    }

    func setCapturePairingToken(_ token: String?) {
        let value = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        capturePairingToken = value?.isEmpty == false ? value : nil
    }

    func recordPage(_ key: String) {
        record(key: key, type: "page", screenName: nil)
    }

    /// `screenName` is mandatory server-side for anchors — skip rather than
    /// send a call guaranteed to be rejected if it isn't set yet.
    func recordAnchor(_ key: String, screenName: String?) {
        guard let screenName, !screenName.isEmpty else {
            DigiaLog.warning(
                "[ComponentRegistry] Skipping anchor \"\(key)\" — no current screen name set yet. "
                    + "Call Digia.setCurrentScreen() before this anchor registers."
            )
            return
        }
        record(key: key, type: "anchor", screenName: screenName)
    }

    func recordSlot(_ key: String, screenName: String?) {
        record(key: key, type: "slot", screenName: screenName)
    }

    func uploadPageCapture(_ capture: [String: Any]) async -> Bool {
        guard isEnabled, isDebugBuildFlag, let config, let deviceId,
              let capturePairingToken,
              let pageKey = capture["pageKey"] as? String,
              !pageKey.isEmpty
        else { return false }
        var authenticatedCapture = capture
        authenticatedCapture["pairingToken"] = capturePairingToken
        guard let body = try? JSONSerialization.data(withJSONObject: authenticatedCapture),
              body.count <= 8 * 1024 * 1024
        else { return false }
        let headers = [
            "Content-Type": "application/json",
            "x-digia-project-id": config.apiKey,
            "x-digia-device-id": deviceId,
        ]
        do {
            let status = try await sender.post(
                url: DigiaEndpoints.recordPageCapture,
                body: body,
                headers: headers
            )
            DigiaLog.log("[ComponentRegistry] recordPageCapture HTTP \(status) (pageKey=\(pageKey))")
            return (200...299).contains(status)
        } catch {
            DigiaLog.warning("[ComponentRegistry] recordPageCapture post failed: \(error)")
            return false
        }
    }

    private func record(key: String, type: String, screenName: String?) {
        guard isEnabled, isDebugBuildFlag, let config, let deviceId else { return }

        let dedupeKey = "\(type):\(key):\(screenName ?? "")"
        guard seen.insert(dedupeKey).inserted else { return }

        recordedThisSession.append(RecordedComponentEntry(type: type, key: key, screenName: screenName))

        var entry: [String: Any] = ["componentKey": key, "componentType": type, "platform": "ios"]
        if let screenName, !screenName.isEmpty { entry["screenName"] = screenName }

        // Serialize before crossing into Task — [String: Any] isn't Sendable
        // under strict concurrency, so only Data/String cross the boundary.
        guard let body = try? JSONSerialization.data(withJSONObject: ["components": [entry]]) else { return }
        let headers = [
            "Content-Type": "application/json",
            "x-digia-project-id": config.apiKey,
            "x-digia-device-id": deviceId,
        ]
        send(body: body, headers: headers, key: key)
    }

    private func send(body: Data, headers: [String: String], key: String) {
        Task { [sender] in
            do {
                let status = try await sender.post(url: DigiaEndpoints.recordComponents, body: body, headers: headers)
                DigiaLog.log("[ComponentRegistry] recordComponents HTTP \(status) (componentKey=\(key))")
            } catch {
                DigiaLog.warning("[ComponentRegistry] recordComponents post failed: \(error)")
            }
        }
    }
}
