import Foundation

/// A `campaign_test` SSE event, parsed off the wire. `campaign` is the
/// campaign's current full definition (same shape as one item of
/// `getCampaigns`' response array: `id`/`campaignKey`/`campaignType`/nested
/// `templateConfig`/`frequency`) — the SDK renders directly from it, never via
/// `campaignId` looked up in its own campaign cache.
struct LiveTestInvocation {
    let testInvocationId: String
    let campaignId: String
    /// Raw JSON, or `nil` if the field was missing/not an object — callers
    /// treat that as `.campaignNotFound` (malformed message).
    let campaign: [String: Any]?
    /// Raw JSON variable values (string/number/bool) — coerced to
    /// `[String: String]` only at the point a `CEPTriggerPayload` is built.
    let variables: [String: Any]
}

/// Bounded failure codes from the backend doc's ACK table. `wireValue` is
/// exactly what's sent in the ACK's `reason.code`.
enum LiveTestFailureCode: String {
    case campaignNotFound = "campaign_not_found"
    case missingVariable = "missing_variable"
    case noMatchingScreen = "no_matching_screen"
    case templateError = "template_error"
    case renderError = "render_error"

    var wireValue: String { rawValue }
}

/// Connection state of the live-test SSE stream, surfaced in the debug settings screen.
enum LiveTestConnectionState {
    case disconnected, connecting, connected, error
}

/// Tracks one in-flight invocation from `received` through its terminal ACK.
///
/// `shown`/`failed` are mutually exclusive and single-fire (idempotent) —
/// matching the backend's own idempotent ACK handling — since a live test's
/// render path could in principle reach a terminal outcome from more than one
/// call site.
@MainActor
final class LiveTestContext {
    let testInvocationId: String
    private let reporter: LiveTestAckReporter
    private let onTerminal: () -> Void
    private var terminalReported = false

    init(testInvocationId: String, reporter: LiveTestAckReporter, onTerminal: @escaping () -> Void) {
        self.testInvocationId = testInvocationId
        self.reporter = reporter
        self.onTerminal = onTerminal
    }

    /// The campaign is confirmed visible on screen.
    func reportShown() {
        guard !terminalReported else { return }
        terminalReported = true
        reporter.postShown(testInvocationId)
        onTerminal()
    }

    /// The campaign could not be shown. `message` is optional, length-limited,
    /// debug-only free text — never a stable machine-readable value.
    func reportFailed(_ code: LiveTestFailureCode, message: String? = nil) {
        guard !terminalReported else { return }
        terminalReported = true
        reporter.postFailed(testInvocationId, code: code, message: message)
        onTerminal()
    }
}
