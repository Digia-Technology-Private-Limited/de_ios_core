import Foundation
import Testing
@testable import DigiaEngage

/// Guards `GameHaptics`' 30 ms throttle: the production line is the
/// `timestamp - last < throttleInterval` comparison in `play`.
@Suite("Game haptics", .tags(.unit, .gamification))
@MainActor
struct GameHapticsTests {

    @Test("second haptic within 30 ms is dropped")
    func throttleDropsSecondHapticWithin30ms() {
        var now = 100.0
        var fired: [GameHapticStyle] = []
        let haptics = GameHaptics(sensors: ["haptics"], now: { now }, fire: { fired.append($0) })

        #expect(haptics.play(.light))
        now += 0.029
        #expect(!haptics.play(.medium))
        #expect(fired == [.light])
        now += 0.001
        #expect(haptics.play(.medium))
        #expect(fired == [.light, .medium])
    }

    @Test("haptic is ignored without the haptics sensor")
    func ignoredWithoutHapticsSensor() {
        var fired: [GameHapticStyle] = []
        let haptics = GameHaptics(sensors: ["accelerometer"], now: { 0 }, fire: { fired.append($0) })

        #expect(!haptics.play(.success))
        #expect(fired.isEmpty)
    }
}

/// Guards `GamePauseController`'s hold-while-paused logic: the production
/// lines are the `isPaused` branch in `receiveOutcome` and the ordered
/// `onResume`-then-held-outcome delivery in `resume`.
@Suite("Game pause controller", .tags(.unit, .gamification))
@MainActor
struct GamePauseControllerTests {

    @Test("outcome received while paused is held until resume")
    func holdsOutcomeWhilePaused() {
        let controller = GamePauseController<String>()
        var events: [String] = []
        controller.onResume = { events.append("resume") }
        controller.onOutcome = { events.append("outcome:\($0)") }

        controller.pause()
        controller.receiveOutcome("win")
        #expect(events.isEmpty)

        controller.resume()
        #expect(events == ["resume", "outcome:win"])
    }

    @Test("outcome received while open is delivered at once")
    func deliversImmediatelyWhenOpen() {
        let controller = GamePauseController<String>()
        var delivered: [String] = []
        controller.onOutcome = { delivered.append($0) }

        controller.receiveOutcome("win")
        #expect(delivered == ["win"])
    }
}
