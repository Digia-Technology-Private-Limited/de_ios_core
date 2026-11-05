import Foundation

/// Holds every rule signal until the campaigns are ready (DMC R58), then
/// replays them in arrival order. Each replay carries how long the signal was
/// held, so a wait started by it counts from when it happened.
///
/// Loading that takes too long drops what it held: a signal older than
/// ``maxHoldMs`` at ``open()`` is not replayed, so a welcome nudge never shows
/// long after the open that earned it. At most ``maxHeld`` signals are kept,
/// the newest, so a load that never succeeds holds a bounded list.
@MainActor
final class SignalGate {
    static let maxHoldMs = 10_000
    static let maxHeld = 200

    private let send: (RuleSignal, Int) -> Void
    private let nowMs: () -> Int
    private var held: [(RuleSignal, Int)] = []
    private(set) var isOpen = false

    init(send: @escaping (RuleSignal, Int) -> Void, nowMs: @escaping () -> Int) {
        self.send = send
        self.nowMs = nowMs
    }

    func send(_ signal: RuleSignal) {
        if isOpen {
            send(signal, 0)
        } else {
            if held.count == Self.maxHeld { held.removeFirst() }
            held.append((signal, nowMs()))
        }
    }

    /// Ready: replays what was held, oldest first, then passes signals through.
    func open() {
        isOpen = true
        let now = nowMs()
        let replay = held
        held.removeAll()
        for (signal, at) in replay {
            if now - at <= Self.maxHoldMs { send(signal, now - at) }
        }
    }

    /// Loading failed or the session was reset: drops what was held and holds
    /// again.
    func close() {
        isOpen = false
        held.removeAll()
    }

    /// The app went to the background before ready: drops what was held.
    func dropHeld() {
        held.removeAll()
    }
}
