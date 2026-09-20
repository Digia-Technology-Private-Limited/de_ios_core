import Foundation
import Testing
@testable import DigiaEngage

/// N4b's contract in one sentence: **every invocation ends in a terminal ACK,
/// and the ACK speaks the shared diagnostic vocabulary, not a live-test-only
/// twin of it.**
///
/// A dashboard row that stops moving is the worst outcome this feature has —
/// a PM cannot tell "the campaign never fired" from "the SDK crashed" from
/// "the network ate the answer", and the three have completely different
/// fixes. Each test here is one of the holes that produced that row, or a pin
/// on the wire the reliability work makes load-bearing.
///
/// The twin of Flutter's `live_test_reliability_test.dart` (F6/F6b) — same
/// scenarios, so the two stacks are comparable line by line.
@Suite("Live-test reliability (N4b)", .serialized)
struct LiveTestReliabilityTests {

    // MARK: - The ACK wire

    @Test("pins every Phase-B reason wire the live-test path can send")
    func pinsPhaseBReasonWires() {
        // Longhand on purpose: every entry here needs a copy entry on the
        // dashboard, and this list is the only place the two can be compared.
        // The five coarse codes this replaced (`render_error` and friends)
        // are retired from the SDK but must stay in the dashboard's copy
        // table forever — apps shipped with them are on real phones for
        // months.
        let wires: [(DiagnosticReason, String)] = [
            (DropReason.notInitialized, "not_initialized"),
            (DropReason.screenNotTargeted, "screen_not_targeted"),
            (DropReason.anchorNotRegistered, "anchor_not_registered"),
            (DropReason.invalidConfig, "invalid_config"),
            (DropReason.surfaceBusy, "surface_busy"),
            (DropReason.superseded, "superseded"),
            (DropReason.timeout, "timeout"),
            (DropReason.error, "error"),
            (TimelineReason.malformedCampaignSkipped, "malformed_campaign_skipped"),
            (TimelineReason.campaignUnsupported, "campaign_unsupported"),
        ]
        #expect(wires.count == 10)
        for (reason, expected) in wires {
            #expect(reason.wire == expected)
        }
    }

    @Test("pins the synthetic cepCampaignId prefix and its inverse")
    func pinsCepIdPrefix() {
        // Every `isLiveTestCepId` branch in routing keys off this, so changing
        // it silently routes live tests down the organic path — analytics and
        // frequency capping included.
        #expect(liveTestCepId("inv-1") == "digia_live_test:inv-1")
        #expect(isLiveTestCepId("digia_live_test:inv-1"))
        #expect(!isLiveTestCepId("inv-1"))
        #expect(testInvocationIdOf("digia_live_test:inv-1") == "inv-1")
        #expect(testInvocationIdOf("inv-1") == nil)
    }

    @MainActor
    @Test("pins the three ACK statuses and the failed payload shape")
    func pinsAckStatuses() async {
        let sender = FakeSender(outcomes: [.success(200), .success(200), .success(200)])
        let reporter = LiveTestAckReporter(sender: sender)
        reporter.configure(config: DigiaConfig(apiKey: "test-key"), deviceId: "device-1")

        // Awaited individually — each call spawns its own unstructured Task,
        // and letting one land before firing the next is what pins the
        // ordering below rather than racing three tasks against each other.
        reporter.postReceived("inv-1")
        await sender.waitForAttempts(1)
        reporter.postShown("inv-1")
        await sender.waitForAttempts(2)
        reporter.postFailed("inv-1", code: DropReason.error, message: "it went wrong")
        await sender.waitForAttempts(3)

        #expect(await sender.count == 3)
        #expect(await sender.status(0) == "received")
        #expect(await sender.status(1) == "shown")
        #expect(await sender.status(2) == "failed")
        #expect(await sender.reasonCode(2) == "error")
        #expect(await sender.reasonMessage(2) == "it went wrong")
    }

    @MainActor
    @Test("bounds the free-text message")
    func boundsMessage() async {
        let sender = FakeSender(outcomes: [.success(200)])
        let reporter = LiveTestAckReporter(sender: sender)
        reporter.configure(config: DigiaConfig(apiKey: "test-key"), deviceId: "device-1")

        reporter.postFailed(
            "inv-1", code: DropReason.error, message: String(repeating: "x", count: 500))
        await sender.waitForAttempts(1)

        let message = await sender.reasonMessage(0)
        #expect((message?.count ?? 0) < 250)
        #expect(message?.hasSuffix("…") == true)
    }

    // MARK: - ACK delivery (retry)

    @MainActor
    @Test("retries a 5xx and a network error, then stops on success")
    func retriesTransientFailures() async {
        struct NetworkError: Error {}
        let sender = FakeSender(outcomes: [.success(500), .failure(NetworkError()), .success(200)])
        let reporter = LiveTestAckReporter(sender: sender)
        reporter.retryPauses = [0.01, 0.01]
        reporter.configure(config: DigiaConfig(apiKey: "test-key"), deviceId: "device-1")

        reporter.postShown("inv-1")
        await sender.waitForAttempts(3)

        #expect(await sender.count == 3)
    }

    @MainActor
    @Test("gives up after three attempts")
    func givesUpAfterThreeAttempts() async {
        let sender = FakeSender(outcomes: [.success(500), .success(500), .success(500), .success(500)])
        let reporter = LiveTestAckReporter(sender: sender)
        reporter.retryPauses = [0.01, 0.01]
        reporter.configure(config: DigiaConfig(apiKey: "test-key"), deviceId: "device-1")

        reporter.postShown("inv-1")
        // Give it time well past the two short pauses; a fourth attempt would
        // mean the give-up bound was not honoured.
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(await sender.count == 3)
    }

    @MainActor
    @Test("a 4xx is a verdict — gives up immediately, no retry")
    func fourXXGivesUpImmediately() async {
        let sender = FakeSender(outcomes: [.success(404), .success(200)])
        let reporter = LiveTestAckReporter(sender: sender)
        reporter.retryPauses = [0.01, 0.01]
        reporter.configure(config: DigiaConfig(apiKey: "test-key"), deviceId: "device-1")

        reporter.postShown("inv-1")
        try? await Task.sleep(nanoseconds: 100_000_000)

        // The same bytes would be refused again — retrying only delays the
        // give-up.
        #expect(await sender.count == 1)
    }

    // MARK: - Live-only events

    @MainActor
    @Test("live-only events ride their own endpoint, not the ACK state machine")
    func liveEventsRideOwnEndpoint() async {
        let sender = FakeSender(outcomes: [.success(200)])
        let reporter = LiveTestAckReporter(sender: sender)
        reporter.configure(config: DigiaConfig(apiKey: "test-key"), deviceId: "device-1")

        reporter.postEvent(
            "inv-1", type: "dismissed", payload: ["reason": "scrim_tap", "completed": false])
        await sender.waitForAttempts(1)

        #expect(await sender.url(0)?.hasSuffix("/testInvocation/event") == true)
        #expect(await sender.type(0) == "dismissed")
        // shown is already terminal — this is not an ACK transition.
        #expect(await sender.hasStatusField(0) == false)
    }

    // MARK: - The per-invocation watchdog

    @MainActor
    @Test("the watchdog fires a terminal ACK if nothing else does")
    func watchdogFiresDefaultTimeout() async {
        let sender = FakeSender(outcomes: [.success(200)])
        let reporter = LiveTestAckReporter(sender: sender)
        reporter.configure(config: DigiaConfig(apiKey: "test-key"), deviceId: "device-1")

        var terminalFired = false
        // Held for the test's duration — the watchdog's Task captures `self`
        // weakly (matching production, which is always held by
        // `liveTestContexts`), so an unretained context here would simply
        // vanish before the timer fires.
        let context = LiveTestContext(
            testInvocationId: "inv-1",
            reporter: reporter,
            onTerminal: { terminalFired = true },
            timeout: 0.02
        )
        await sender.waitForAttempts(1)

        #expect(terminalFired)
        #expect(await sender.reasonCode(0) == "timeout")
        withExtendedLifetime(context) {}
    }

    @MainActor
    @Test("expectSlotToMount narrows the watchdog's verdict")
    func watchdogNarrowedForInline() async {
        let sender = FakeSender(outcomes: [.success(200)])
        let reporter = LiveTestAckReporter(sender: sender)
        reporter.configure(config: DigiaConfig(apiKey: "test-key"), deviceId: "device-1")

        let context = LiveTestContext(
            testInvocationId: "inv-1", reporter: reporter, onTerminal: {}, timeout: 0.02
        )
        context.expectSlotToMount()
        await sender.waitForAttempts(1)

        // The same answer a guide gets for the same situation: the named
        // mount point is not on the screen the user is looking at.
        #expect(await sender.reasonCode(0) == "anchor_not_registered")
        withExtendedLifetime(context) {}
    }

    @MainActor
    @Test("is disarmed by an explicit reportShown before it fires")
    func watchdogDisarmedByShown() async {
        let sender = FakeSender(outcomes: [.success(200)])
        let reporter = LiveTestAckReporter(sender: sender)
        reporter.configure(config: DigiaConfig(apiKey: "test-key"), deviceId: "device-1")

        let context = LiveTestContext(
            testInvocationId: "inv-1", reporter: reporter, onTerminal: {}, timeout: 0.02
        )
        context.reportShown()
        // Long enough that a still-armed watchdog would have fired a second,
        // conflicting ACK.
        try? await Task.sleep(nanoseconds: 60_000_000)

        #expect(await sender.count == 1)
        #expect(await sender.status(0) == "shown")
        withExtendedLifetime(context) {}
    }

    @MainActor
    @Test("reportFailed is idempotent — a second call changes nothing")
    func reportFailedIsIdempotent() async {
        let sender = FakeSender(outcomes: [.success(200), .success(200)])
        let reporter = LiveTestAckReporter(sender: sender)
        reporter.configure(config: DigiaConfig(apiKey: "test-key"), deviceId: "device-1")

        let context = LiveTestContext(
            testInvocationId: "inv-1", reporter: reporter, onTerminal: {}, timeout: 10
        )
        context.reportFailed(DropReason.surfaceBusy, message: "first")
        // What `supersedeLiveTest` does to a test that has already appeared —
        // safe to call, and must not overwrite the first answer.
        context.reportFailed(DropReason.superseded, message: "superseded by a newer live test")
        await sender.waitForAttempts(1)
        try? await Task.sleep(nanoseconds: 30_000_000)

        #expect(await sender.count == 1)
        withExtendedLifetime(context) {}
    }

    @MainActor
    @Test("invalidate cancels the watchdog without posting any ACK")
    func invalidateCancelsWithoutPosting() async {
        let sender = FakeSender(outcomes: [.success(200)])
        let reporter = LiveTestAckReporter(sender: sender)
        reporter.configure(config: DigiaConfig(apiKey: "test-key"), deviceId: "device-1")

        var terminalFired = false
        let context = LiveTestContext(
            testInvocationId: "inv-1",
            reporter: reporter,
            onTerminal: { terminalFired = true },
            timeout: 0.02
        )
        context.invalidate()
        try? await Task.sleep(nanoseconds: 60_000_000)

        #expect(await sender.count == 0)
        // An abandoned invocation is not a terminal one.
        #expect(!terminalFired)
        withExtendedLifetime(context) {}
    }
}

// MARK: - Test double

/// Scripts a sequence of outcomes for `LiveTestAckReporter`'s injected
/// `AnalyticsSender`, and records every attempt.
///
/// An actor, because the reporter's retry loop runs off the caller's actor —
/// and its recorded bodies are exposed only through typed accessor methods,
/// never as raw `[String: Any]`, which cannot cross an actor boundary under
/// strict concurrency.
private actor FakeSender: AnalyticsSender {
    enum Outcome {
        case success(Int)
        case failure(Error)
    }

    private(set) var attempts = 0
    private var bodies: [[String: Any]] = []
    private var recordedUrls: [String] = []
    private var outcomes: [Outcome]

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func post(url: String, body: Data, headers: [String: String]) async throws -> Int {
        attempts += 1
        recordedUrls.append(url)
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            bodies.append(object)
        }
        guard !outcomes.isEmpty else { return 200 }
        switch outcomes.removeFirst() {
        case .success(let code): return code
        case .failure(let error): throw error
        }
    }

    /// Polls until at least `count` attempts have landed, or gives up after a
    /// short bound — used instead of a fixed sleep so the pin/status tests
    /// (no retries) don't need to guess a delay.
    func waitForAttempts(_ count: Int) async {
        for _ in 0..<50 {
            if attempts >= count { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    var count: Int { bodies.count }
    func url(_ index: Int) -> String? { recordedUrls.indices.contains(index) ? recordedUrls[index] : nil }
    func status(_ index: Int) -> String? { body(index)?["status"] as? String }
    func type(_ index: Int) -> String? { body(index)?["type"] as? String }
    func hasStatusField(_ index: Int) -> Bool { body(index)?["status"] != nil }
    func reasonCode(_ index: Int) -> String? { reason(index)?["code"] as? String }
    func reasonMessage(_ index: Int) -> String? { reason(index)?["message"] as? String }

    private func body(_ index: Int) -> [String: Any]? {
        bodies.indices.contains(index) ? bodies[index] : nil
    }
    private func reason(_ index: Int) -> [String: Any]? { body(index)?["reason"] as? [String: Any] }
}
