import Foundation

/// Reports pages/anchors/slots seen at runtime to the Engage Component
/// Registry (`POST {baseUrl}/api/v1/engage/sdk/recordComponents`), so a PM
/// can curate them on the dashboard instead of typing keys by hand.
///
/// Only active when `isEnabled` — the debug-only "recording mode" toggle a
/// developer flips from `DigiaDebugSettingsView` — and only ever on a debug
/// build (`isDebugBuild`, passed once at `configure` time), defense in depth in
/// case a persisted `true` toggle somehow survives into a non-debug install.
///
/// Fire-and-forget, one request per newly-seen key, mirrors
/// `SurveySubmissionReporter`'s network pattern rather than the heavier
/// retrying `AnalyticsService` queue — a dropped registration ping is
/// low-stakes and self-heals next time the key is seen. Deliberately no
/// batching/queueing: this only runs while a developer has recording mode on
/// and is manually walking the app, so request volume is inherently low — a
/// debounce/batch buffer would be complexity this doesn't need.
@MainActor
final class ComponentRegistryService {
    private static let keyEnabled = "digia_component_registry_recording_enabled"

    private let defaults: UserDefaults
    private let sender: any AnalyticsSender

    private var config: DigiaConfig?
    private var deviceId: String?
    private var isDebugBuildFlag = false

    private(set) var isEnabled = false

    /// `"<type>:<key>:<screenName>"` → already sent this process lifetime. Not
    /// persisted: the backend call is an idempotent upsert, so re-sending known
    /// keys on a fresh process start is harmless (and keeps `lastSeenAt` fresh) —
    /// no cross-session dedupe is needed. This is what actually matters here —
    /// without it, a view that re-registers repeatedly (e.g. an anchor inside a
    /// recycled list cell) could refire the same key many times a second.
    private var seen = Set<String>()

    init(defaults: UserDefaults = .standard, sender: any AnalyticsSender = URLSessionAnalyticsSender()) {
        self.defaults = defaults
        self.sender = sender
    }

    /// Called once from `SDKInstance.completeInitialization` after the device id
    /// is known.
    func configure(config: DigiaConfig, deviceId: String, isDebugBuild: Bool) {
        self.config = config
        self.deviceId = deviceId
        self.isDebugBuildFlag = isDebugBuild
        self.isEnabled = defaults.bool(forKey: Self.keyEnabled)
    }

    /// Flips the persisted recording-mode toggle. Called from
    /// `DigiaDebugSettingsView`.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.keyEnabled)
    }

    func recordPage(_ key: String) {
        record(key: key, type: "page", screenName: nil)
    }

    /// `screenName` is mandatory for anchors server-side — if it isn't known yet
    /// (the developer hasn't called `Digia.setCurrentScreen` before this anchor
    /// registered), skip rather than send a call guaranteed to be rejected.
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

    private func record(key: String, type: String, screenName: String?) {
        guard isEnabled, isDebugBuildFlag, let config, let deviceId else { return }

        let dedupeKey = "\(type):\(key):\(screenName ?? "")"
        guard seen.insert(dedupeKey).inserted else { return }

        var entry: [String: Any] = ["componentKey": key, "componentType": type, "platform": "ios"]
        if let screenName, !screenName.isEmpty { entry["screenName"] = screenName }

        // Serialize on the main actor and hand the Task only Sendable values
        // (Data, [String: String], String) — [String: Any] itself can't safely
        // cross into an unstructured Task under strict concurrency.
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
