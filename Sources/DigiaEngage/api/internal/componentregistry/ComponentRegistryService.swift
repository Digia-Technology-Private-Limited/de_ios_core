import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Batches pages/anchors/slots seen at runtime and reports them to the Engage
/// Component Registry (`POST {baseUrl}/api/v1/engage/sdk/recordComponents`), so
/// a PM can curate them on the dashboard instead of typing keys by hand.
///
/// Only active when `isEnabled` — the debug-only "recording mode" toggle a
/// developer flips from `DigiaDebugSettingsView` — and only ever on a debug
/// build (`isDebugBuild`, passed once at `configure` time), defense in depth in
/// case a persisted `true` toggle somehow survives into a non-debug install.
///
/// Fire-and-forget, mirrors `SurveySubmissionReporter`'s network pattern rather
/// than the heavier retrying `AnalyticsService` queue — a dropped registration
/// ping is low-stakes and self-heals next time the key is seen. Owns its own
/// background-flush observer (mirrors `AnalyticsService`) rather than routing
/// through `SDKInstance`'s lifecycle handling.
@MainActor
final class ComponentRegistryService {
    private static let keyEnabled = "digia_component_registry_recording_enabled"

    /// Server does not validate `componentKey` itself — enforced here per the
    /// SDK-team note.
    private static let keyPattern = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_]{0,63}$")

    /// Coalesces near-simultaneous registrations into one batched call.
    private static let debounceSeconds: TimeInterval = 0.7

    private let defaults: UserDefaults
    private let sender: any AnalyticsSender

    private var config: DigiaConfig?
    private var deviceId: String?
    private var isDebugBuildFlag = false

    private(set) var isEnabled = false

    /// `"<type>:<key>:<screenName>"` → already sent this process lifetime. Not
    /// persisted: the backend call is an idempotent upsert, so re-sending known
    /// keys on a fresh process start is harmless (and keeps `lastSeenAt` fresh) —
    /// no cross-session dedupe is needed.
    private var seen = Set<String>()
    private var pending: [[String: Any]] = []
    private var debounceTimer: Timer?
    private var backgroundObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, sender: any AnalyticsSender = URLSessionAnalyticsSender()) {
        self.defaults = defaults
        self.sender = sender

        #if canImport(UIKit)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.flush() }
        }
        #endif
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
    /// `DigiaDebugSettingsView`. Turning it off cancels any pending flush —
    /// there's no "unregister" concept server-side, so nothing further to do.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.keyEnabled)
        if !enabled {
            debounceTimer?.invalidate()
            debounceTimer = nil
            pending.removeAll()
        }
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
        guard isEnabled, isDebugBuildFlag, config != nil else { return }

        guard Self.isValidKey(key) else {
            DigiaLog.warning(
                "[ComponentRegistry] Dropping invalid componentKey \"\(key)\" — must match ^[a-z][a-z0-9_]{0,63}$."
            )
            return
        }

        let dedupeKey = "\(type):\(key):\(screenName ?? "")"
        guard seen.insert(dedupeKey).inserted else { return }

        var entry: [String: Any] = ["componentKey": key, "componentType": type, "platform": "ios"]
        if let screenName, !screenName.isEmpty { entry["screenName"] = screenName }
        pending.append(entry)
        scheduleFlush()
    }

    private func scheduleFlush() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.debounceSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.debounceTimer = nil
                await self?.flush()
            }
        }
    }

    /// Flushes any pending batch immediately. Called by the debounce timer, and
    /// as a safety net when the app backgrounds with a flush still pending.
    func flush() async {
        debounceTimer?.invalidate()
        debounceTimer = nil

        guard let config, let deviceId, !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()

        do {
            let body = try JSONSerialization.data(withJSONObject: ["components": batch])
            let headers = [
                "Content-Type": "application/json",
                "x-digia-project-id": config.apiKey,
                "x-digia-device-id": deviceId,
            ]
            let status = try await sender.post(url: DigiaEndpoints.recordComponents, body: body, headers: headers)
            DigiaLog.log("[ComponentRegistry] recordComponents HTTP \(status) (\(batch.count) component(s))")
        } catch {
            DigiaLog.warning("[ComponentRegistry] recordComponents post failed: \(error)")
        }
    }

    private static func isValidKey(_ key: String) -> Bool {
        let range = NSRange(key.startIndex..<key.endIndex, in: key)
        return keyPattern.firstMatch(in: key, range: range) != nil
    }
}
