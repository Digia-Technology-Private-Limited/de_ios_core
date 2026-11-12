import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// Owns the game state machine (`loading` → `idle` → `playing` → `done` →
/// `closed`) and the skin-to-SDK message intake. T7 drives it to the depth the
/// ERD gives T7: the ready handshake, the ready timeout, and close. `playing`
/// and `done` exist so T8 wires `playRequested` and the outcome without
/// reshaping this type; until then a `playRequested` parks on `onUnhandled`.
///
/// Unknown, malformed, or over-16 KB messages are dropped and logged, and the
/// first drop per session is flagged for T12's `bridge_message_dropped`.
@MainActor
final class GameBridge {
    /// The SDK's bridge version (ERD A1). A skin declaring a higher one is
    /// refused before this bridge is ever built (T10).
    nonisolated static let bridgeVersion = 1
    /// Seconds from load start to `ready` before the container closes quietly.
    nonisolated static let readyTimeoutSeconds = 5.0
    /// Skin messages above this many UTF-8 bytes are dropped, never parsed.
    nonisolated static let maxMessageBytes = 16 * 1024

    enum State: Equatable {
        case loading
        case idle
        case playing
        case done
        case closed
    }

    private(set) var state: State = .loading
    /// Set once per session by T12's `bridge_message_dropped` emit.
    private(set) var didRecordDrop = false

    /// Fires once, when `ready` moves `loading` → `idle`.
    var onReady: (@MainActor () -> Void)?
    /// Fires once, when the session reaches `closed` via close or timeout.
    /// Timeout close fires `onFailed` instead — never both.
    var onClosed: (@MainActor () -> Void)?
    /// Fires once, when the session closes as a failure.
    var onFailed: (@MainActor (GameFailure) -> Void)?
    /// Skin messages this stage does not handle yet. T8 takes these over to
    /// call `play`, send `outcome`/`refused`, and run the game actions.
    var onUnhandled: (@MainActor (String, [String: Any]) -> Void)?

    /// Messages the intake accepts by `type`. Anything else is dropped.
    private static let knownTypes: Set<String> = [
        "ready", "playRequested", "revealed", "copyCode", "useReward",
        "playNext", "close", "haptic", "startMotion", "stopMotion", "error",
    ]

    /// (Re)enters `loading`. Returns a generation token so the one-shot ready
    /// timer fires only for the load that armed it.
    private var generation = 0

    func beginLoading() -> Int {
        state = .loading
        generation += 1
        return generation
    }

    /// The entry point for `digia.postMessage`. Never throws: a bad message is
    /// a drop and a log, never a crash on a render path.
    func receive(_ body: Any?) {
        guard state != .closed else { return }
        guard let text = body as? String,
              text.utf8.count <= Self.maxMessageBytes,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            recordDrop()
            return
        }
        guard Self.knownTypes.contains(type) else {
            recordDrop()
            return
        }
        switch type {
        case "ready":
            if state == .loading {
                state = .idle
                onReady?()
            }
        case "close":
            close()
        case "error":
            if let message = object["message"] as? String, !message.isEmpty {
                log.d("Game skin error: \(message)")
            }
        default:
            // `playRequested`, result-screen notes, and game actions belong to
            // T8, which replaces this default with the play call. Parked here
            // so the intake shape stays final.
            onUnhandled?(type, object)
        }
    }

    /// Fires from the one-shot ready timer. Only a session still `loading`
    /// closes here; anything past `ready` is unaffected.
    func readyTimeoutFired(generation: Int) {
        guard generation == self.generation, state == .loading else { return }
        state = .closed
        log.w("Game closed — ready timed out")
        onFailed?(.readyTimeout)
    }

    /// `playRequested` accepted: `idle` → `playing`. False in any other state,
    /// so a repeated request while a play is in flight or done is ignored.
    func beginPlay() -> Bool {
        guard state == .idle else { return false }
        state = .playing
        return true
    }

    /// The play result reached the skin: `playing` → `done`. False if the
    /// session closed while the play was in flight.
    func finishPlay() -> Bool {
        guard state == .playing else { return false }
        state = .done
        return true
    }

    /// Native close button, back, skin `close`, or teardown. First call wins;
    /// teardown after a failure is a no-op, never a second callback.
    func close() {
        guard state != .closed else { return }
        state = .closed
        onClosed?()
    }

    /// `window.digiaGame.receive(<json>)`. The payload is JSON-encoded into the
    /// script, never string-concatenated, so text values cannot break out.
    func script(for payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return "window.digiaGame.receive(\(json))"
    }

    private func recordDrop() {
        if !didRecordDrop {
            didRecordDrop = true
            log.w("Game bridge message dropped (unknown, malformed, or over 16 KB)")
        } else if log.isEnabled(.debug) {
            log.d("Game bridge message dropped (unknown, malformed, or over 16 KB)")
        }
    }
}
