import Foundation

/// A `campaign_test` SSE event, parsed off the wire.
struct LiveTestInvocation {
    let testInvocationId: String
    let campaignId: String
    let campaign: [String: Any]?
    let variables: [String: Any]
}

/// Transient Guide payload delivered to the React Native live-test renderer.
public struct LiveTestGuideRenderRequest {
    public let testInvocationId: String
    public let cepCampaignId: String
    public let campaignJson: String
    public let variablesJson: String

    init(
        testInvocationId: String,
        cepCampaignId: String,
        campaignJson: String,
        variablesJson: String
    ) {
        self.testInvocationId = testInvocationId
        self.cepCampaignId = cepCampaignId
        self.campaignJson = campaignJson
        self.variablesJson = variablesJson
    }
}

/// Failure codes from the backend's ACK table; `wireValue` is what's sent on the wire.
enum LiveTestFailureCode: String {
    case campaignNotFound = "campaign_not_found"
    case missingVariable = "missing_variable"
    case noMatchingScreen = "no_matching_screen"
    case templateError = "template_error"
    case renderError = "render_error"

    var wireValue: String { rawValue }
}

/// Equatable so the debug bubble can key `.task(id:)` off it to restart the
/// "connecting" pulse animation on every reconnect.
enum LiveTestConnectionState: Equatable {
    case disconnected, connecting, connected, error
}

/// Tracks one in-flight invocation through its terminal ACK; shown/failed are
/// single-fire (idempotent).
@MainActor
final class LiveTestContext {
    let testInvocationId: String
    private let reporter: LiveTestAckReporter
    private let onTerminal: (_ shown: Bool) -> Void
    private var terminalReported = false

    init(testInvocationId: String, reporter: LiveTestAckReporter, onTerminal: @escaping (Bool) -> Void) {
        self.testInvocationId = testInvocationId
        self.reporter = reporter
        self.onTerminal = onTerminal
    }

    func reportShown() {
        guard !terminalReported else { return }
        terminalReported = true
        reporter.postShown(testInvocationId)
        onTerminal(true)
    }

    func reportFailed(_ code: LiveTestFailureCode, message: String? = nil) {
        guard !terminalReported else { return }
        terminalReported = true
        reporter.postFailed(testInvocationId, code: code, message: message)
        onTerminal(false)
    }
}
