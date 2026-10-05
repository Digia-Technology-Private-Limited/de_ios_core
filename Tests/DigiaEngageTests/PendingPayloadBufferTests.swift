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

    private func trigger(_ id: String) -> CEPTriggerPayload {
        CEPTriggerPayload(cepCampaignId: id, campaignKey: id, cepMetadata: [:])
    }

    private func makeBuffer(
        arrivalOrder: Bool = false,
        onDrop: @escaping (String, DropReason) -> Void
    ) -> PendingPayloadBuffer {
        let clock = clock
        return PendingPayloadBuffer(
            onDrop: { onDrop($0.cepCampaignId, $1) },
            arrivalOrder: arrivalOrder,
            now: { clock.now },
            createTimer: { clock.schedule($0, $1) }
        )
    }

    private func ids(_ triggers: [CEPTriggerPayload]) -> [String] { triggers.map(\.cepCampaignId) }

    @Test("flush is newest first")
    func newestFirst() {
        let buffer = makeBuffer { _, _ in }
        ["a", "b", "c"].forEach { buffer.add(trigger($0)) }
        #expect(ids(buffer.takeAll()) == ["c", "b", "a"])
        #expect(buffer.length == 0)
        #expect(clock.pending == 0)
    }

    @Test("arrival order flushes oldest first")
    func arrivalOrder() {
        let buffer = makeBuffer(arrivalOrder: true) { _, _ in }
        ["a", "b", "c"].forEach { buffer.add(trigger($0)) }
        #expect(ids(buffer.takeAll()) == ["a", "b", "c"])
    }

    @Test("a trigger with the same cepCampaignId replaces the held one, with no drop")
    func replaceSameId() {
        var dropped: [String] = []
        let buffer = makeBuffer(arrivalOrder: true) { id, _ in dropped.append(id) }
        ["a", "b", "a", "c"].forEach { buffer.add(trigger($0)) }
        #expect(ids(buffer.takeAll()) == ["b", "a", "c"])
        #expect(dropped.isEmpty)
    }

    @Test("21 triggers: the oldest drops with superseded")
    func capacity() {
        var dropped: [(String, String)] = []
        let buffer = makeBuffer { dropped.append(($0, $1.wire)) }
        (1...21).map(String.init).forEach { buffer.add(trigger($0)) }
        #expect(buffer.length == 20)
        #expect(dropped.count == 1)
        #expect(dropped.first?.0 == "1")
        #expect(dropped.first?.1 == "superseded")
    }

    @Test("a trigger held for more than 5 minutes expires with pending_expired; younger ones stay")
    func expiry() {
        var dropped: [(String, String)] = []
        let buffer = makeBuffer { dropped.append(($0, $1.wire)) }
        buffer.add(trigger("old"))
        clock.advance(120)
        buffer.add(trigger("young"))
        clock.advance(180)
        #expect(dropped.map(\.0) == ["old"])
        #expect(dropped.first?.1 == "pending_expired")
        #expect(buffer.length == 1)
        clock.advance(120)
        #expect(dropped.map(\.0) == ["old", "young"])
        #expect(buffer.length == 0)
        #expect(clock.pending == 0)
    }

    @Test("a replaced trigger keeps its first hold time")
    func replaceKeepsHoldTime() {
        var dropped: [String] = []
        let buffer = makeBuffer { id, _ in dropped.append(id) }
        buffer.add(trigger("a"))
        clock.advance(200)
        buffer.add(trigger("a"))
        clock.advance(100)
        #expect(dropped == ["a"])
    }

    @Test("init takes 10 s: nothing expires and everything flushes")
    func slowInit() {
        var dropped: [String] = []
        let buffer = makeBuffer { id, _ in dropped.append(id) }
        buffer.add(trigger("a"))
        clock.advance(10)
        buffer.add(trigger("b"))
        #expect(ids(buffer.takeAll()) == ["b", "a"])
        #expect(dropped.isEmpty)
        clock.advance(600)
        #expect(dropped.isEmpty)
    }

    @Test("dropAll drops every trigger with the given reason and stops the timer")
    func dropAll() {
        var dropped: [(String, String)] = []
        let buffer = makeBuffer { dropped.append(($0, $1.wire)) }
        ["a", "b"].forEach { buffer.add(trigger($0)) }
        buffer.dropAll(DropReason.initializationFailed)
        #expect(dropped.map(\.0) == ["b", "a"])
        #expect(dropped.allSatisfy { $0.1 == "initialization_failed" })
        #expect(clock.pending == 0)
    }
}
