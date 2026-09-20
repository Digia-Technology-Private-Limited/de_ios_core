import Foundation

/// One health event, already projected to exactly what may leave the device.
///
/// Fully `Sendable` by construction — every field is a `String`, an optional
/// `String`, or a `[String: String]` — so it can cross from whatever thread
/// ``DigiaLogger`` dispatched on into the `@MainActor`-isolated analytics
/// pipeline without a raw `[String: Any]` ever crossing that boundary.
struct HealthEventPayload: Sendable {
    /// The dashboard-authored key, when the record named a campaign. Never an
    /// id — see ``TimelineRecord/campaignKey``.
    let campaignKey: String?

    /// The allowlisted reason's pinned wire string.
    let reason: String

    /// The stage's pinned wire string, when the record carried one.
    let stage: String?

    /// The per-reason projection from ``HealthReasons/detailKeys``, or `nil`
    /// when the reason carries none.
    let detail: [String: String]?

    /// `"debug"` or `"release"`, stamped once at ``HealthSink/activate(_:)``.
    let buildMode: String
}

/// What a health event is handed to. Injected so this file never imports
/// `AnalyticsService` — the same cycle ``ConsoleSink`` avoids by taking its
/// severity predicate rather than reaching for the logger.
typealias HealthReporter = @Sendable (HealthEventPayload) -> Void

/// Sink #4: fleet health telemetry, for Digia.
///
/// The third audience. The host developer has the console, the campaign
/// creator has the on-device timeline and the live-test dashboard, and until
/// now nobody could answer *"which campaigns are silently failing in the
/// fleet, and why?"* — the failures it exists for are contract violations
/// between dashboard-published content and a shipped SDK, happening
/// unattended where the only party who can act is on our side of the wire.
///
/// **Not a log uplink.** No free text ever leaves the device, and that is
/// structural rather than a rule to remember: ``emit(_:)`` serialises an
/// explicit field list, never reads `TimelineRecord/message`, and copies only
/// the `extras` keys ``HealthReasons/detailKeys`` names for that reason. There
/// is no code path that carries a free-text value to the wire, so none can be
/// taken by accident.
///
/// **No new transport.** A health event is an ordinary first-party analytics
/// event with `event_name: 'sdk_health'`, riding the existing envelope,
/// batching, retry and identity. Transport code is exactly the code the
/// release chain says not to ship twice.
///
/// Four brakes, because fleet scale multiplies everything — one malformed
/// campaign × every session × every user of every app carrying it:
///
/// | Brake | Where |
/// |---|---|
/// | The allowlist | ``HealthReasons/reasons`` — a closed, central list |
/// | Dedup | first occurrence per key per app session |
/// | Session cap | server-configurable, ``defaultSessionCap`` absent |
/// | The kill switch | ``applyBundleConfig(enabled:sessionCap:)`` deregisters the sink outright |
///
/// It is **not** in ``DigiaLogger``'s static registry. The other sinks are
/// always present; this one registers only once the analytics pipeline it
/// sends through is up (``activate(_:)``), and unregisters entirely when the
/// server says stop — zero work, not zero sends.
///
/// Every mutable field is behind one lock: records reach ``accepts(_:)`` and
/// ``emit(_:)`` from wherever ``DigiaLogger`` dispatched — the main actor, a
/// `URLSession` callback, a watchdog task — the same "called from anywhere"
/// contract ``ScreenSink`` documents.
final class HealthSink: DiagnosticSink, @unchecked Sendable {
    /// The one instance the SDK wires up. A singleton for the same reason
    /// `ScreenSink.shared` is: records come from everywhere and the counters
    /// are per app session.
    static let shared = HealthSink()

    /// A fresh instance exists so a test can exercise the allowlist, dedup and
    /// cap without racing every other suite's records through the singleton.
    init() {}

    /// The event name on the existing analytics envelope.
    static let eventName = "sdk_health"

    /// Events per app session when the server names no cap.
    ///
    /// The server's value rides the campaign bundle and is read once per
    /// successful fetch; a session whose fetch failed runs on this.
    static let defaultSessionCap = 20

    private let lock = NSLock()
    private var seen: Set<String> = []
    private var cap = HealthSink.defaultSessionCap
    private var sent = 0
    private var report: HealthReporter?
    private var registered = false
    private var buildMode = "release"

    /// Whether the sink is currently in ``DigiaLogger``'s registry.
    var isRegistered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return registered
    }

    /// How many events this app session has sent. Diagnostic; the cap is
    /// enforced in ``accepts(_:)``.
    var sentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    /// Registers the sink and points it at `report`.
    ///
    /// Called once init has an analytics pipeline configured, and deliberately
    /// **before** the campaign bundle is fetched: `fetch_failed_auth` is one of
    /// the four motivating failures, and a sink that waited for a successful
    /// fetch could never report the fetch that failed. Until the bundle
    /// answers, the defaults are in force — switch on, cap
    /// ``defaultSessionCap``.
    func activate(_ report: @escaping HealthReporter) {
        var shouldRegister = false
        lock.lock()
        self.report = report
        if !registered {
            registered = true
            buildMode = DigiaDebugDetection.isDebugBuild() ? "debug" : "release"
            shouldRegister = true
        }
        lock.unlock()
        if shouldRegister {
            DigiaLogger.registerSink(self)
        }
    }

    /// Applies the server's switch and cap from a successfully fetched bundle.
    ///
    /// Read once per fetch and held for the session — no mid-session re-read,
    /// so a changed server value applies from the next session that fetches
    /// successfully. `nil` arguments mean the bundle said nothing usable,
    /// which is "leave it alone", never "reset to default".
    func applyBundleConfig(enabled: Bool?, sessionCap: Int?) {
        var shouldDeactivate = false
        lock.lock()
        if let sessionCap, sessionCap >= 0 { cap = sessionCap }
        if enabled == false { shouldDeactivate = true }
        lock.unlock()
        if shouldDeactivate { deactivate() }
    }

    /// Unregisters the sink for the rest of the session.
    func deactivate() {
        lock.lock()
        guard registered else {
            lock.unlock()
            return
        }
        registered = false
        lock.unlock()
        DigiaLogger.unregisterSink(self)
    }

    /// Clears every counter and unregisters. Tests only — nothing in the SDK's
    /// own paths resets a session's dedup state.
    func resetForTest() {
        deactivate()
        lock.lock()
        seen.removeAll()
        sent = 0
        cap = Self.defaultSessionCap
        report = nil
        buildMode = "release"
        lock.unlock()
    }

    /// Pure, per spec: it decides, it does not remember. The seen-set is
    /// written in ``emit(_:)``, so an ``accepts(_:)`` that nobody acts on
    /// cannot silently consume a reason's one allowed report.
    func accepts(_ record: TimelineRecord) -> Bool {
        guard let reason = record.reason else { return false }
        let wire = reason.wire
        guard HealthReasons.reasons.contains(wire) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard sent < cap else { return false }
        return !seen.contains(dedupKey(record, wire))
    }

    func emit(_ record: TimelineRecord) {
        // Unreachable through `DigiaLogger`, which calls `accepts` first.
        // Kept because a sink that relies on its caller's ordering is one
        // refactor away from a null dereference on a render path.
        guard let reason = record.reason else { return }
        let wire = reason.wire
        let detail = projectedDetail(record, wire)

        let reporter: HealthReporter?
        let mode: String
        lock.lock()
        seen.insert(dedupKey(record, wire))
        sent += 1
        reporter = report
        mode = buildMode
        lock.unlock()

        reporter?(
            HealthEventPayload(
                campaignKey: record.campaignKey,
                reason: wire,
                stage: record.stage?.wire,
                detail: detail.isEmpty ? nil : detail,
                buildMode: mode
            )
        )
    }

    /// The per-reason projection: only the keys ``HealthReasons/detailKeys``
    /// names, and a key absent from the record is absent here rather than
    /// null.
    private func projectedDetail(_ record: TimelineRecord, _ wire: String) -> [String: String] {
        guard let allowed = HealthReasons.detailKeys[wire], !allowed.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for key in allowed {
            if let value = record.extras[key] { result[key] = value }
        }
        return result
    }

    /// First occurrence per key per app session. `|` is a safe separator:
    /// every part is a symbol, an id or a dashboard-authored key.
    private func dedupKey(_ record: TimelineRecord, _ wire: String) -> String {
        if HealthReasons.campaignlessReasons.contains(wire) { return wire }
        var key = "\(wire)|\(record.campaignKey ?? "")"
        if let extraKey = HealthReasons.dedupExtraKey[wire] {
            key += "|\(record.extras[extraKey] ?? "")"
        }
        return key
    }
}
