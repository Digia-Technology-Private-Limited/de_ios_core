import Foundation

/// Sink #2: the on-device campaign timeline.
///
/// The flow it exists for: a campaign creator sees odd behaviour in the app,
/// opens the debug screen, and reads what just happened. Every rule here
/// follows from that one sentence.
///
/// - **Always recording, always registered.** Recording only while the screen
///   is open would answer nothing — it is opened *after* the fact.
/// - **Not gated on `logLevel`.** Severity gates the console; ``accepts(_:)``
///   gates on ``TimelineRecord/stage``. A release build at the default `error`
///   level still fills this buffer, because a campaign creator's rows are not
///   errors. That independence is the whole design.
/// - **Bounded and memory-only.** A ring of ``capacity`` records, no disk, no
///   upload; it dies with the process. This is within-session recall, not
///   history, and the cost of always-on is a hundred small values.
///
/// platform note: Dart's twin needs no lock — one isolate, one thread. Records
/// reach this one from URLSession callbacks, watchdog tasks and the main actor
/// alike, so the ring is guarded and the SwiftUI notification is hopped to the
/// main queue.
final class ScreenSink: ObservableObject, DiagnosticSink, @unchecked Sendable {
    /// The buffer the timeline screen reads. A singleton because the screen is
    /// reached from anywhere and the records must already be there.
    static let shared = ScreenSink()

    /// The SDK always uses ``shared``. A fresh instance exists so a test can
    /// exercise the ring and the gate without racing every other suite's
    /// records through the singleton.
    init() {}

    /// How many records the ring holds before the oldest falls off.
    static let capacity = 100

    /// Bumped once per batch of new records. The screen observes this rather
    /// than a stream, so a closed screen costs nothing and an open one rebuilds
    /// from ``snapshot()``.
    @Published private(set) var revision: Int = 0

    private let lock = NSLock()
    private var records: [TimelineRecord] = []
    private var bumpScheduled = false

    func accepts(_ record: TimelineRecord) -> Bool { record.stage != nil }

    func emit(_ record: TimelineRecord) {
        lock.lock()
        if records.count >= Self.capacity { records.removeFirst() }
        records.append(record)
        lock.unlock()
        scheduleBump()
    }

    /// Everything recorded, newest first.
    func snapshot() -> [TimelineRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.reversed()
    }

    /// Empties the ring. For tests and a future "clear" affordance on the
    /// screen; nothing in the SDK's own paths calls it.
    func clear() {
        lock.lock()
        records.removeAll()
        lock.unlock()
        scheduleBump()
    }

    /// Notifies observers on the next main-queue turn, coalescing a burst into
    /// one bump.
    ///
    /// Never synchronously, and never on the emitting thread: ``emit(_:)`` can
    /// run from a gesture handler or from inside a SwiftUI view update, and
    /// `@Published` notifies its observers inline — which would mean mutating
    /// view state during a frame the *host app* owns, over a diagnostic. An
    /// async hop runs after the current turn's synchronous work has finished,
    /// so the rebuild lands on the next frame where it belongs.
    ///
    /// platform note: Dart coalesces onto a microtask, which is the same
    /// property — after the frame's synchronous work, before the next frame.
    private func scheduleBump() {
        lock.lock()
        if bumpScheduled {
            lock.unlock()
            return
        }
        bumpScheduled = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.bumpScheduled = false
            self.lock.unlock()
            self.revision &+= 1
        }
    }
}
