import Foundation
import Testing
@testable import DigiaEngage

/// `HealthSink`'s four brakes — the allowlist, dedup, the session cap and the
/// kill switch — exercised against a fresh, non-shared instance so this suite
/// never touches `HealthSink.shared`'s process-wide registration and can run
/// alongside every other suite without racing them.
@Suite("HealthSink")
struct HealthSinkTests {

    private func record(
        _ reason: DiagnosticReason?,
        campaignKey: String? = nil,
        stage: TimelineStage? = .parse,
        extras: [String: String] = [:]
    ) -> TimelineRecord {
        TimelineRecord(
            timestamp: Date(timeIntervalSince1970: 0),
            severity: .error,
            tag: "DIGIA",
            message: "message",
            stage: stage,
            reason: reason,
            campaignKey: campaignKey,
            extras: extras
        )
    }

    /// Records every payload a sink hands it, for assertions.
    ///
    /// `@unchecked Sendable` + a lock, same as `DigiaLoggerTests`'s
    /// `RecordingSink` — `capture` is handed to `HealthSink` as a
    /// `@Sendable` closure, so the recorder itself must be safe to call from
    /// wherever that closure runs.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [HealthEventPayload] = []

        var payloads: [HealthEventPayload] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func capture(_ payload: HealthEventPayload) {
            lock.lock()
            stored.append(payload)
            lock.unlock()
        }
    }

    // MARK: - The allowlist

    @Test("accepts only a record whose reason is on the central allowlist")
    func allowlistGate() {
        let sink = HealthSink()
        #expect(sink.accepts(record(TimelineReason.malformedCampaignSkipped)))
        #expect(sink.accepts(record(DropReason.unknownCampaignKey)))
        #expect(sink.accepts(record(DropReason.invalidConfig)))
        // Not on the allowlist — e.g. a plain lifecycle beat.
        #expect(!sink.accepts(record(TimelineReason.displayed)))
        #expect(!sink.accepts(record(DropReason.frequencyCapped)))
        // No reason at all.
        #expect(!sink.accepts(record(nil)))
    }

    // MARK: - Dedup

    @Test("dedups first occurrence per (reason, campaign) per session")
    func dedupsPerCampaign() {
        let sink = HealthSink()
        let recorder = Recorder()
        sink.activate(recorder.capture)

        let first = record(TimelineReason.malformedCampaignSkipped, campaignKey: "cmp_a")
        #expect(sink.accepts(first))
        sink.emit(first)
        #expect(recorder.payloads.count == 1)

        // Same reason, same campaign: suppressed.
        #expect(!sink.accepts(first))

        // Same reason, different campaign: sent.
        let second = record(TimelineReason.malformedCampaignSkipped, campaignKey: "cmp_b")
        #expect(sink.accepts(second))
        sink.emit(second)
        #expect(recorder.payloads.count == 2)
    }

    @Test("dedups per-token for unknown_design_token, per campaign")
    func dedupsPerToken() {
        let sink = HealthSink()
        let recorder = Recorder()
        sink.activate(recorder.capture)

        let tokenA = record(
            TimelineReason.unknownDesignToken, campaignKey: "cmp_a",
            extras: ["token": "brand_primary", "kind": "color"])
        let tokenB = record(
            TimelineReason.unknownDesignToken, campaignKey: "cmp_a",
            extras: ["token": "brand_secondary", "kind": "color"])

        #expect(sink.accepts(tokenA))
        sink.emit(tokenA)
        // A second, distinct broken token in the *same* campaign is not
        // suppressed — collapsing it would hide a real, separate failure.
        #expect(sink.accepts(tokenB))
        sink.emit(tokenB)
        #expect(recorder.payloads.count == 2)

        // The exact same token again: suppressed.
        #expect(!sink.accepts(tokenA))
    }

    @Test("campaignless reasons dedup on the symbol alone")
    func campaignlessDedup() {
        let sink = HealthSink()
        let recorder = Recorder()
        sink.activate(recorder.capture)

        let first = record(TimelineReason.designTokensUnreadable, campaignKey: nil)
        #expect(sink.accepts(first))
        sink.emit(first)

        // A second occurrence, even naming a campaign (should never happen for
        // this reason, but the dedup key must not accidentally admit it).
        let second = record(TimelineReason.designTokensUnreadable, campaignKey: "cmp_a")
        #expect(!sink.accepts(second))
        #expect(recorder.payloads.count == 1)
    }

    // MARK: - Pending mode (SP10)

    @Test("pending mode queues early events, dedups them, and flushes once on activate")
    func pendingModeQueuesAndFlushes() {
        let sink = HealthSink()
        sink.beginPending()
        defer { sink.deactivate() }
        #expect(sink.isRegistered)

        let early = record(DropReason.notReady, campaignKey: "cmp_early")
        #expect(sink.accepts(early))
        sink.emit(early)
        // A duplicate before activation is deduplicated.
        #expect(!sink.accepts(early))

        let recorder = Recorder()
        sink.activate(recorder.capture)
        #expect(recorder.payloads.map(\.campaignKey) == ["cmp_early"])
        #expect(recorder.payloads.first?.reason == DropReason.notReady.wire)

        // A second activate (a retry) does not flush it again.
        sink.activate(recorder.capture)
        #expect(recorder.payloads.count == 1)
    }

    @Test("queued events count toward the session cap")
    func pendingModeCountsTowardCap() {
        let sink = HealthSink()
        sink.beginPending()
        defer { sink.deactivate() }
        for index in 0..<25 {
            let r = record(DropReason.notReady, campaignKey: "cmp_\(index)")
            if sink.accepts(r) { sink.emit(r) }
        }
        #expect(sink.sentCount == HealthSink.defaultSessionCap)

        let recorder = Recorder()
        sink.activate(recorder.capture)
        #expect(recorder.payloads.count == HealthSink.defaultSessionCap)
        let late = record(DropReason.notReady, campaignKey: "cmp_late")
        #expect(!sink.accepts(late))
    }

    // MARK: - Session cap

    @Test("stops sending once the session cap is reached, regardless of dedup keys")
    func sessionCap() {
        let sink = HealthSink()
        let recorder = Recorder()
        sink.activate(recorder.capture)
        sink.applyBundleConfig(enabled: nil, sessionCap: 2)

        for index in 0..<5 {
            let r = record(TimelineReason.malformedCampaignSkipped, campaignKey: "cmp_\(index)")
            if sink.accepts(r) { sink.emit(r) }
        }

        #expect(recorder.payloads.count == 2)
        #expect(sink.sentCount == 2)
    }

    @Test("defaults the cap to 20 when the bundle names none")
    func defaultCap() {
        let sink = HealthSink()
        #expect(HealthSink.defaultSessionCap == 20)
        sink.activate { _ in }
        for index in 0..<25 {
            let r = record(TimelineReason.malformedCampaignSkipped, campaignKey: "cmp_\(index)")
            if sink.accepts(r) { sink.emit(r) }
        }
        #expect(sink.sentCount == 20)
    }

    @Test("a negative or garbage session cap from the bundle is ignored")
    func garbageCapIgnored() {
        let sink = HealthSink()
        sink.activate { _ in }
        sink.applyBundleConfig(enabled: nil, sessionCap: -5)
        for index in 0..<25 {
            let r = record(TimelineReason.malformedCampaignSkipped, campaignKey: "cmp_\(index)")
            if sink.accepts(r) { sink.emit(r) }
        }
        // The SDK's own default stands — a negative cap never narrows to zero.
        #expect(sink.sentCount == HealthSink.defaultSessionCap)
    }

    /// A duplicate the dedup set suppressed does not consume cap — the cap
    /// counts what was actually sent.
    @Test("a suppressed duplicate does not consume the session cap")
    func duplicateDoesNotConsumeCap() {
        let sink = HealthSink()
        let recorder = Recorder()
        sink.activate(recorder.capture)
        sink.applyBundleConfig(enabled: nil, sessionCap: 2)

        let a = record(TimelineReason.malformedCampaignSkipped, campaignKey: "cmp_a")
        #expect(sink.accepts(a))
        sink.emit(a)
        #expect(sink.sentCount == 1)

        // Re-submitting the exact same record several times must not eat
        // budget — only dedup should reject it, never the cap.
        #expect(!sink.accepts(a))
        #expect(!sink.accepts(a))
        #expect(sink.sentCount == 1)

        // A distinct record still fits under the cap (2), proving the
        // duplicates above consumed none of it.
        let b = record(TimelineReason.malformedCampaignSkipped, campaignKey: "cmp_b")
        #expect(sink.accepts(b))
        sink.emit(b)
        #expect(sink.sentCount == 2)
    }

    // MARK: - The kill switch

    @Test("an explicit false kill switch deregisters the sink")
    func killSwitchDeactivates() {
        let sink = HealthSink()
        sink.activate { _ in }
        #expect(sink.isRegistered)
        sink.applyBundleConfig(enabled: false, sessionCap: nil)
        #expect(!sink.isRegistered)
    }

    @Test("absent, null or non-boolean bundle values leave the switch on")
    func killSwitchDefaultsOn() {
        let sink = HealthSink()
        sink.activate { _ in }
        sink.applyBundleConfig(enabled: nil, sessionCap: nil)
        #expect(sink.isRegistered)
        sink.applyBundleConfig(enabled: true, sessionCap: nil)
        #expect(sink.isRegistered)
    }

    // MARK: - Detail projection

    @Test("detail carries only the reason's allowlisted keys")
    func detailProjection() {
        let sink = HealthSink()
        let recorder = Recorder()
        sink.activate(recorder.capture)

        let r = record(
            TimelineReason.unknownDesignToken, campaignKey: "cmp_a",
            extras: ["token": "brand_primary", "kind": "color", "unrelated": "leaked?"])
        sink.emit(r)

        #expect(recorder.payloads.count == 1)
        #expect(recorder.payloads[0].detail == ["token": "brand_primary", "kind": "color"])
    }

    @Test("campaign_unsupported's detail allows both readings — precondition and type")
    func campaignUnsupportedDetailUnion() {
        let sink = HealthSink()
        let recorder = Recorder()
        sink.activate(recorder.capture)

        // This core's one live emit site (an unparseable stateful-timer
        // config) sends only `type`; the spec's `precondition` reading stays
        // representable without a second wire change.
        let r = record(
            TimelineReason.campaignUnsupported, campaignKey: "cmp_a",
            extras: ["type": "inlineCanvas"])
        sink.emit(r)
        #expect(recorder.payloads[0].detail == ["type": "inlineCanvas"])
    }

    @Test("a reason with no detail keys sends no detail at all")
    func noDetailWhenNoneAllowed() {
        let sink = HealthSink()
        let recorder = Recorder()
        sink.activate(recorder.capture)

        sink.emit(record(TimelineReason.malformedCampaignSkipped, campaignKey: "cmp_a"))
        #expect(recorder.payloads[0].detail == nil)
    }

    // MARK: - build_mode

    @Test("stamps build_mode once, at activation")
    func buildModeStamped() {
        let sink = HealthSink()
        let recorder = Recorder()
        sink.activate(recorder.capture)
        sink.emit(record(TimelineReason.malformedCampaignSkipped, campaignKey: "cmp_a"))
        // The test host is always a debug-eligible (simulator) build.
        #expect(recorder.payloads[0].buildMode == "debug")
    }

    // MARK: - Registry integration

    @Test("activate registers with DigiaLogger; a log call with an allowlisted reason reaches it")
    func integratesWithDigiaLoggerRegistry() {
        let sink = HealthSink()
        let recorder = Recorder()
        sink.activate(recorder.capture)
        defer { sink.deactivate() }

        let logger = DigiaLogger()
        logger.e(
            "Campaign skipped",
            campaign: "cmp_integration",
            stage: .parse,
            reason: TimelineReason.malformedCampaignSkipped
        )

        #expect(recorder.payloads.contains { $0.campaignKey == "cmp_integration" })
    }

    @Test("deactivate removes the sink from DigiaLogger's registry")
    func deactivateUnregisters() {
        let sink = HealthSink()
        sink.activate { _ in }
        #expect(sink.isRegistered)
        sink.deactivate()
        #expect(!sink.isRegistered)

        let recorder = Recorder()
        sink.activate(recorder.capture)
        sink.deactivate()

        let logger = DigiaLogger()
        logger.e(
            "Campaign skipped after deactivate",
            campaign: "cmp_after_deactivate",
            stage: .parse,
            reason: TimelineReason.malformedCampaignSkipped
        )
        #expect(!recorder.payloads.contains { $0.campaignKey == "cmp_after_deactivate" })
    }
}
