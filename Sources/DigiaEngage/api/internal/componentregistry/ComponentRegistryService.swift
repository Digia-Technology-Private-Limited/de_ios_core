import Foundation
import Combine

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

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
    private static let keyEnabled = "recording_enabled"

    private let storage: LocalStorage
    private let sender: any AnalyticsSender

    private var config: DigiaConfig?
    private var deviceId: String?
    private var isDebugBuildFlag = false

    /// Kept in sync across `RecordingBadgeView` and the debug/session screens.
    @Published private(set) var isEnabled = false

    /// Every distinct key recorded this process, in first-seen order — what
    /// `DigiaRecordedSessionScreen` lists. Not persisted, see `seen` below.
    @Published private(set) var recordedThisSession: [RecordedComponentEntry] = []

    /// `"<type>:<key>:<screenName>"` already sent this process. Not persisted —
    /// the backend upsert is idempotent, so resending on a fresh process is
    /// harmless. Without this, a recycled view (e.g. a list-cell anchor) could
    /// refire the same key repeatedly.
    private var seen = Set<String>()

    /// Anchor keys seen before they could be sent: no screen yet, or `configure`
    /// has not run (iOS configures after the async bundle fetch, and an RN or
    /// SwiftUI tree mounts before that). The backend rejects an anchor without a
    /// `screenName`, so they wait for `attachPendingAnchors(to:)`, which
    /// `SDKInstance` calls when either input arrives. First-seen order, deduped.
    private var pendingAnchors: [String] = []
    /// Anchor keys are ≤ 64 chars and an app has tens of anchors, not thousands.
    /// Past the cap the newest key is dropped, with one warning per key.
    private static let pendingAnchorCap = 64
    /// The one actionable hint this feature keeps: once per process, at `warn`,
    /// and only while recording is actually on.
    private var didWarnNoScreen = false

    private let debugOverlay: DigiaDebugOverlayController?

    init(
        storage: LocalStorage = UserDefaultsLocalStorage().scoped("registry"),
        sender: any AnalyticsSender = URLSessionAnalyticsSender(),
        debugOverlay: DigiaDebugOverlayController? = nil
    ) {
        self.storage = storage
        self.sender = sender
        self.debugOverlay = debugOverlay
    }

    convenience init(
        defaults: UserDefaults,
        sender: any AnalyticsSender = URLSessionAnalyticsSender(),
        debugOverlay: DigiaDebugOverlayController? = nil
    ) {
        if defaults.bool(forKey: "digia_component_registry_recording_enabled") && !defaults.bool(forKey: "registry.recording_enabled") {
            defaults.set(true, forKey: "registry.recording_enabled")
        }
        self.init(
            storage: UserDefaultsLocalStorage(defaults: defaults).scoped("registry"),
            sender: sender,
            debugOverlay: debugOverlay
        )
    }

    /// Called once from `SDKInstance.completeInitialization` after the device id
    /// is known.
    func configure(config: DigiaConfig, deviceId: String, isDebugBuild: Bool) {
        self.config = config
        self.deviceId = deviceId
        self.isDebugBuildFlag = isDebugBuild
        self.isEnabled = storage.bool(forKey: Self.keyEnabled)
    }

    /// Flips the persisted recording toggle. Also shows the bubble if hidden
    /// (so it's visible when recording starts) — but turning recording off
    /// doesn't hide it back; bubble visibility is otherwise independent.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        storage.set(enabled, forKey: Self.keyEnabled)
        if enabled, let debugOverlay, !debugOverlay.isVisible {
            debugOverlay.setVisible(true)
        }
    }

    func recordPage(_ key: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        record(key: trimmedKey, type: "page", screenName: nil)
    }

    /// `screenName` is mandatory server-side for anchors. An anchor seen before
    /// the screen (or before `configure`) waits instead of being dropped and is
    /// attributed to the first screen reported afterwards.
    func recordAnchor(_ key: String, screenName: String?) {
        // Recording is off: nothing to do and nothing to buffer. Checked first so
        // a release build with the toggle off pays one branch here.
        if isConfigured && !isRecording { return }
        let trimmedScreen = screenName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConfigured, let trimmedScreen, !trimmedScreen.isEmpty else {
            bufferPendingAnchor(key)
            return
        }
        record(key: key, type: "anchor", screenName: trimmedScreen)
    }

    /// `screenName` is mandatory server-side for anchors. An anchor seen before
    /// the screen (or before `configure`) waits instead of being dropped and is
    /// attributed to the first screen reported afterwards. `SDKInstance` calls
    /// this from `setCurrentScreen` and after `configure`.
    func attachPendingAnchors(to screenName: String?) {
        guard isConfigured, !pendingAnchors.isEmpty else { return }
        guard isRecording else { pendingAnchors.removeAll(); return }
        guard let screenName = screenName?.trimmingCharacters(in: .whitespacesAndNewlines), !screenName.isEmpty else {
            warnNoScreenOnce(first: pendingAnchors[0])
            return
        }
        let keys = pendingAnchors
        pendingAnchors.removeAll()
        log.d("Attributing \(keys.count) anchor(s) seen before the screen was known (screen=\(screenName))")
        for key in keys { record(key: key, type: "anchor", screenName: screenName) }
    }

    private var isConfigured: Bool { config != nil && deviceId != nil }
    private var isRecording: Bool { isEnabled && isDebugBuildFlag }

    private func bufferPendingAnchor(_ key: String) {
        guard !pendingAnchors.contains(key) else { return }
        guard pendingAnchors.count < Self.pendingAnchorCap else {
            log.w("Anchor not buffered — \(Self.pendingAnchorCap) already waiting for a screen (anchor=\(key))")
            return
        }
        pendingAnchors.append(key)
        log.d("Anchor waiting for a screen (anchor=\(key))")
        if isConfigured { warnNoScreenOnce(first: key) }
    }

    private func warnNoScreenOnce(first key: String) {
        guard isRecording, !didWarnNoScreen else { return }
        didWarnNoScreen = true
        log.w(
            "Anchors are waiting for a screen name (first=\(key)) — they record "
                + "once Digia.setCurrentScreen() is called."
        )
    }

    func recordSlot(_ key: String, screenName: String?) {
        record(key: key, type: "slot", screenName: screenName)
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
                log.d("Components posted (status=\(status), componentKey=\(key))")
            } catch {
                log.e("Components post failed", error: error)
            }
        }
    }
}
