import Foundation

/// A `campaign_test` SSE event, parsed off the wire.
struct LiveTestInvocation {
    let testInvocationId: String
    let campaignId: String
    let campaign: [String: Any]?
    let variables: [String: Any]
}

/// Equatable so the debug bubble can key `.task(id:)` off it to restart the
/// "connecting" pulse animation on every reconnect.
enum LiveTestConnectionState: Equatable {
    case disconnected, connecting, connected, error
}

/// Tracks one in-flight invocation through its terminal ACK.
///
/// **Every invocation ends in a terminal ACK.** That is the whole contract: a
/// PM who pressed "Test on device" gets an answer, not a row that quietly
/// stops. Explicit paths (``reportShown``/``reportFailed``) cover what the SDK
/// can see; the watchdog armed in ``init(testInvocationId:reporter:onTerminal:timeout:)``
/// covers what it cannot — a campaign that routed "accepted" and then simply
/// never appeared.
@MainActor
final class LiveTestContext {
    /// How long an invocation may sit without a terminal ACK before the SDK
    /// answers on its own behalf.
    ///
    /// Inside the dashboard's own 15s guess window on purpose: a PM should read
    /// a reason the device actually knows rather than a timeout the dashboard
    /// inferred. The backend's 30s alarm sits outside both and catches only the
    /// case no device can ever answer — an app that died mid-test.
    static let watchdogTimeout: TimeInterval = 10

    let testInvocationId: String
    private let reporter: LiveTestAckReporter
    private let onTerminal: () -> Void
    private let timeout: TimeInterval

    private var terminalReported = false
    private var watchdogTask: Task<Void, Never>?

    /// What the watchdog reports if it fires. `.timeout` is the honest
    /// default — something took the campaign and never showed it —  and
    /// ``expectSlotToMount()`` narrows it for the one case with a better answer.
    private var watchdogCode: DiagnosticReason = DropReason.timeout
    private var watchdogDetail: String?

    /// Extra teardown to run only if the watchdog itself fires — never on an
    /// explicit `reportShown`/`reportFailed`. The one caller today uses it to
    /// dismiss a guide that silently never rendered; nothing about this class
    /// depends on what it does.
    var onWatchdogFired: (() -> Void)?

    init(
        testInvocationId: String,
        reporter: LiveTestAckReporter,
        onTerminal: @escaping () -> Void,
        timeout: TimeInterval = watchdogTimeout
    ) {
        self.testInvocationId = testInvocationId
        self.reporter = reporter
        self.onTerminal = onTerminal
        self.timeout = timeout
        armWatchdog()
    }

    /// Narrows the watchdog to the inline case.
    ///
    /// Inline routing always "succeeds" immediately — there is no synchronous
    /// way to know a matching `DigiaSlot` exists anywhere in the app — so the
    /// watchdog is the only thing standing in for the anchor check a guide
    /// gets. `anchor_not_registered` is the same answer a guide gets for the
    /// same situation: the named mount point this campaign needs is not on
    /// the screen the user is looking at.
    func expectSlotToMount() {
        watchdogCode = DropReason.anchorNotRegistered
        watchdogDetail = "no matching slot for this campaign mounted within \(Int(timeout))s"
    }

    /// The campaign is confirmed visible on screen.
    func reportShown() {
        guard !terminalReported else { return }
        terminalReported = true
        disarm()
        reporter.postShown(testInvocationId)
        onTerminal()
    }

    /// The campaign could not be shown.
    ///
    /// `code` is a ``DiagnosticReason`` — the same pinned symbol the campaign
    /// timeline and analytics use, never a live-test-only twin of it. `message`
    /// is optional, length-limited, debug-only free text — never a stable
    /// machine-readable value.
    func reportFailed(_ code: DiagnosticReason, message: String? = nil) {
        guard !terminalReported else { return }
        terminalReported = true
        disarm()
        reporter.postFailed(testInvocationId, code: code, message: message)
        onTerminal()
    }

    /// Cancels the watchdog without posting a terminal ACK. Used when the
    /// whole live-test service is being torn down or reconfigured (e.g. an RN
    /// JS reload) — the invocation is abandoned, not failed, and the
    /// backend's own `no_response` alarm is what accounts for it from here.
    func invalidate() {
        terminalReported = true
        disarm()
    }

    private func armWatchdog() {
        let timeout = self.timeout
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            let code = self.watchdogCode
            let message = self.watchdogDetail ?? "nothing rendered within \(Int(timeout))s"
            self.reportFailed(code, message: message)
            self.onWatchdogFired?()
        }
    }

    /// Cancelled on every terminal path. Replaces the per-kind timers (inline
    /// 5s, guide-host delay+5s) that used to arm independently and were never
    /// cancelled, so they fired into an already-settled (but idempotent)
    /// context on every successful test.
    private func disarm() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }
}
