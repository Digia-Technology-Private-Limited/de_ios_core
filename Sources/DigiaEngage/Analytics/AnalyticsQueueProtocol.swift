import Foundation

/// An ordered queue of analytics events awaiting delivery.
///
/// Nothing here blocks its caller: ``append(_:maxEvents:)`` and ``size``
/// return at once, and the other operations suspend rather than wait.
/// Operations take effect in call order. Storage failures degrade — at most
/// the affected event is lost — and never throw.
protocol AnalyticsQueueProtocol: AnyObject, Sendable {
    /// Events queued, counting appends not yet written.
    var size: Int { get }
    /// Queues [entry], dropping the oldest events beyond [maxEvents]. A
    /// bounded implementation (such as an in-memory fallback) may hold fewer.
    func append(_ entry: QueueEntry, maxEvents: Int)
    /// The stored count, once earlier operations (and startup) have finished.
    func count() async -> Int
    /// Up to [maxCount] oldest entries, in FIFO order.
    func peek(maxCount: Int) async -> [QueueEntry]
    func remove(eventIds: [String]) async
    /// Increments the attempt counter of [eventIds] and returns those entries.
    @discardableResult
    func incrementAttempt(eventIds: [String]) async -> [QueueEntry]
    func clear() async
}
