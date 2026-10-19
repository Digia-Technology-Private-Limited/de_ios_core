import Foundation
import Testing
@testable import DigiaEngage

/// Port of Flutter `test/dmc_signal_bus_test.dart`.
@Suite("DMC signal bus")
@MainActor
struct DMCSignalBusTests {
    enum TestError: Error { case boom }


    @Test("a throwing handler neither escapes nor strands queued signals")
    func throwingHandler() {
        var handled: [String] = []
        var bus: SignalBus!
        bus = SignalBus { signal, _ in
            guard case .screenViewed(let name) = signal else { return }
            handled.append(name)
            if name == "A" {
                bus.send(.screenViewed("B"))
                throw TestError.boom
            }
        }

        bus.send(.screenViewed("A"))
        #expect(handled == ["A", "B"])
    }
}
