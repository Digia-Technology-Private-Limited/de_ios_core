import Foundation
import Testing

@testable import DigiaEngage

/// The shared plugin pending buffer (#71), on a fake clock and scheduler.
@MainActor
@Suite("PendingPayloadBuffer")
struct PendingPayloadBufferTests {

    /// A manual clock and timer: `advance` moves time and fires due timers.
    @MainActor
    final class FakeClock {
        var now = Date(timeIntervalSince1970: 0)
        private var timers: [(id: Int, due: Date, work: @MainActor () -> Void)] = []
        private var nextId = 0

        var pending: Int { timers.count }

        func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
            nextId += 1
            let id = nextId
            timers.append((id, now.addingTimeInterval(delay), work))
            return { [weak self] in self?.timers.removeAll { $0.id == id } }
        }

        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
            while let index = timers.firstIndex(where: { $0.due <= now }) {
                timers.remove(at: index).work()
            }
        }
    }

    private let clock = FakeClock()

    private func makeBuffer(
        order: PendingPayloadBuffer<String>.Order = .newestFirst,
        onDrop: @escaping (String, DiagnosticReason) -> Void
    ) -> PendingPayloadBuffer<String> {
        let clock = clock
        return PendingPayloadBuffer(
            order: order,
            now: { clock.now },
            schedule: { clock.schedule($0, $1) },
            onDrop: onDrop
        )
    }

    @Test("flush is newest first")
    func newestFirst() {
        let buffer = makeBuffer { _, _ in }
        ["a", "b", "c"].forEach(buffer.add)
        #expect(buffer.drain() == ["c", "b", "a"])
        #expect(buffer.isEmpty)
        #expect(clock.pending == 0)
    }

    @Test("inline order flushes in arrival order with one item per id, and a replace is not a drop")
    func inlineDedup() {
        var dropped: [String] = []
        let buffer = makeBuffer(order: .inline(id: { String($0.prefix(1)) })) { item, _ in dropped.append(item) }
        ["a1", "b1", "a2", "c1"].forEach(buffer.add)
        #expect(buffer.drain() == ["b1", "a2", "c1"])
        #expect(dropped.isEmpty)
    }

    @Test("21 payloads: the oldest drops with superseded")
    func capacity() {
        var dropped: [(String, String)] = []
        let buffer = makeBuffer { dropped.append(($0, $1.wire)) }
        (1...21).map(String.init).forEach(buffer.add)
        #expect(buffer.count == 20)
        #expect(dropped.count == 1)
        #expect(dropped.first?.0 == "1")
        #expect(dropped.first?.1 == "superseded")
    }

    @Test("a payload held for more than 5 minutes expires with pending_expired; younger ones stay")
    func expiry() {
        var dropped: [(String, String)] = []
        let buffer = makeBuffer { dropped.append(($0, $1.wire)) }
        buffer.add("old")
        clock.advance(120)
        buffer.add("young")
        clock.advance(180)
        #expect(dropped.map(\.0) == ["old"])
        #expect(dropped.first?.1 == "pending_expired")
        #expect(buffer.count == 1)
        clock.advance(120)
        #expect(dropped.map(\.0) == ["old", "young"])
        #expect(buffer.isEmpty)
        #expect(clock.pending == 0)
    }

    @Test("init takes 10 s: nothing expires and everything flushes")
    func slowInit() {
        var dropped: [String] = []
        let buffer = makeBuffer { item, _ in dropped.append(item) }
        buffer.add("a")
        clock.advance(10)
        buffer.add("b")
        #expect(buffer.drain() == ["b", "a"])
        #expect(dropped.isEmpty)
        clock.advance(600)
        #expect(dropped.isEmpty)
    }

    @Test("dropAll drops every item with the given reason and stops the timer")
    func dropAll() {
        var dropped: [(String, String)] = []
        let buffer = makeBuffer { dropped.append(($0, $1.wire)) }
        ["a", "b"].forEach(buffer.add)
        buffer.dropAll(DropReason.initializationFailed)
        #expect(dropped.map(\.0) == ["a", "b"])
        #expect(dropped.allSatisfy { $0.1 == "initialization_failed" })
        #expect(clock.pending == 0)
    }

    @Test("isHostNotReady is true only for not_ready and not_initialized drops")
    func hostNotReadyOutcome() {
        #expect(PresentationOutcome.dropped(reason: .notReady, detail: nil).isHostNotReady)
        #expect(PresentationOutcome.dropped(reason: .notInitialized, detail: nil).isHostNotReady)
        #expect(!PresentationOutcome.dropped(reason: .initializationFailed, detail: nil).isHostNotReady)
        #expect(!PresentationOutcome.dismissed(reason: .userClose, completed: true).isHostNotReady)
    }

    @Test("pending_expired wire string")
    func wire() {
        #expect(PendingPayloadReason.pendingExpired.wire == "pending_expired")
        #expect(PendingPayloadReason.allCases.count == 1)
    }
}
