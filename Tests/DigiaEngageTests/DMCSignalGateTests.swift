import Foundation
import Testing
@testable import DigiaEngage

/// Port of Flutter `test/dmc_signal_gate_test.dart`.
///
/// DMC spec R58: before the campaigns are ready every signal is held, replayed
/// in arrival order with its original time, and dropped if loading fails or the
/// app backgrounds first.
@Suite("DMC signal gate")
@MainActor
struct DMCSignalGateTests {

    @MainActor final class Harness {
        var clock = 0
        var sent: [(String, Int)] = []
        var gate: SignalGate!

        init() {
            gate = SignalGate(
                send: { [unowned self] signal, ageMs in
                    sent.append((signal.indexKey, ageMs))
                },
                nowMs: { [unowned self] in clock })
        }
    }

    @Test("replays every kind in arrival order, each with its own held time")
    func replaysInOrder() {
        let harness = Harness()
        harness.gate.send(.appOpened)
        harness.clock = 100
        harness.gate.send(.screenViewed("home"))
        harness.clock = 250
        harness.gate.send(.event("added_to_cart", [:]))
        harness.clock = 300
        harness.gate.send(.anchorVisible("cta"))
        harness.clock = 1000
        harness.gate.open()

        #expect(harness.sent.map(\.0) == [
            "app_opened", "screen_viewed:home", "event:added_to_cart", "anchor_visible:cta",
        ])
        #expect(harness.sent.map(\.1) == [1000, 900, 750, 700])
    }

    @Test("once open, a signal passes straight through with no age")
    func passesThrough() {
        let harness = Harness()
        harness.gate.open()
        harness.clock = 50
        harness.gate.send(.event("x", [:]))
        #expect(harness.sent.map(\.0) == ["event:x"])
        #expect(harness.sent.map(\.1) == [0])
    }

    @Test("held signals are gone when the app backgrounds before ready")
    func dropHeld() {
        let harness = Harness()
        harness.gate.send(.appOpened)
        harness.gate.send(.event("x", [:]))
        harness.gate.dropHeld()
        harness.gate.open()
        #expect(harness.sent.isEmpty)
    }

    @Test("held signals are gone when loading fails, and the gate stays shut")
    func close() {
        let harness = Harness()
        harness.gate.send(.appOpened)
        harness.gate.close()
        harness.gate.send(.event("late", [:]))
        #expect(harness.sent.isEmpty)
        harness.gate.open()
        #expect(harness.sent.map(\.0) == ["event:late"])
    }

    @Test("a slow load replays only what is still recent")
    func slowLoad() {
        let harness = Harness()
        harness.gate.send(.appOpened)
        harness.clock = 5000
        harness.gate.send(.screenViewed("pdp"))
        harness.clock = SignalGate.maxHoldMs + 1
        harness.gate.open()

        #expect(harness.sent.map(\.0) == ["screen_viewed:pdp"])
        #expect(harness.sent.map(\.1) == [SignalGate.maxHoldMs + 1 - 5000])
    }

    @Test("a load that never succeeds keeps only the newest signals")
    func boundedHeld() {
        let harness = Harness()
        for index in 0..<(SignalGate.maxHeld + 3) {
            harness.gate.send(.event("e\(index)", [:]))
        }
        harness.gate.open()

        #expect(harness.sent.count == SignalGate.maxHeld)
        #expect(harness.sent.first?.0 == "event:e3")
    }
}
