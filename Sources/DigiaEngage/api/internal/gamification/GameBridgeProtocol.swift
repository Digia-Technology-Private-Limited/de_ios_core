import Foundation

/// Wire error codes for `{id, type:"error"}` replies — the whole set. A skin
/// feature-detects by sending a request and handling `unsupported`.
enum GameBridgeError: String, Sendable, Error {
    case unsupported
    case badRequest = "bad_request"
    case network
    case timeout
    case server
    /// The session closed before the request was answered.
    case closed
}

/// The session side of the skin bridge: intake, the ready handshake and its
/// timeouts, and close. The presentation drives this, never the other way
/// around; `GameBridge` is the one implementation. The parse/validate logic
/// for each message family stays with the intake in `GameBridge` —
///
/// deliberately one file, not split further.
@MainActor
protocol GameBridgeProtocol: AnyObject {
    var state: GameBridge.State { get }
    var dropNoted: Bool { get }

    var onReady: (@MainActor (Int) -> Void)? { get set }
    var onRepeatedReady: (@MainActor (Int) -> Void)? { get set }
    var onDropped: (@MainActor (String, String?) -> Void)? { get set }
    var onClosed: (@MainActor () -> Void)? { get set }
    var onFailed: (@MainActor (GameFailureReason) -> Void)? { get set }
    var onRequest: (@MainActor (GameBridgeRequest) -> Void)? { get set }
    var onSend: (@MainActor (String) -> Void)? { get set }

    /// The entry point for `digia.postMessage`. Never throws.
    func receive(_ body: Any?)

    /// (Re)enters `loading`. Returns a generation token so a one-shot timer
    /// fires only for the load that armed it.
    func beginLoading() -> Int

    /// Invalidates the armed ready timer (the app left the foreground).
    func cancelReadyTimer()

    /// Fires from the one-shot ready timer.
    func readyTimeoutFired(generation: Int)

    /// Fires from the one-shot load timer.
    func loadTimeoutFired(generation: Int)

    /// Native close button, back, skin `close`, or teardown. First call wins.
    func close()

    /// Answers a request with `{id, type:"result", payload}`.
    func answer(id: String, payload: [String: Any])

    /// Answers a request with `{id, type:"error", payload:{code, message}}`.
    func fail(id: String, code: GameBridgeError, message: String)

    /// Pushes a native→skin message (`init`, `lifecycle`, `viewport`,
    /// `device`, `motionSample`) — no id, no reply.
    func push(type: String, payload: [String: Any])
}
