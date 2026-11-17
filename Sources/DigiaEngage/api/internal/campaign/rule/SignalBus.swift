import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// Hands each rule signal to the engine one at a time, in arrival order. A
/// signal sent while another is handled runs after it, so handling never nests.
/// A handler that throws is logged and skipped; it never reaches the sender and
/// never strands the signals queued behind it.
@MainActor
final class SignalBus {
    private let handle: (RuleSignal, Int) throws -> Void
    private var queue: [(RuleSignal, Int)] = []
    private var draining = false

    init(handle: @escaping (RuleSignal, Int) throws -> Void) {
        self.handle = handle
    }

    /// `ageMs` is how long the signal was held before it was sent.
    func send(_ signal: RuleSignal, ageMs: Int = 0) {
        queue.append((signal, ageMs))
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !queue.isEmpty {
            let (signal, age) = queue.removeFirst()
            do {
                try handle(signal, age)
            } catch {
                log.e("Signal dropped — rule handling threw", error: error)
            }
        }
    }
}
