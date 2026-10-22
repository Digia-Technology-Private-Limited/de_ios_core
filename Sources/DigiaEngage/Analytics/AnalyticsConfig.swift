import Foundation

public struct AnalyticsConfig: Sendable, Equatable {
    public let enabled: Bool
    public let flushIntervalMs: Int
    public let flushBatchSize: Int
    /// Maximum events sent in one batch, from 1 to ``maxBatchSizeLimit``. A
    /// value outside that range is clamped, with a warning.
    public let maxBatchSize: Int
    public let queueMaxEvents: Int
    public let sessionTimeoutMs: Int

    /// The largest ``maxBatchSize`` the SDK uses. Each batch is encoded on the
    /// main actor and sent as one request, so a larger batch means a longer
    /// stall and a heavier request; a smaller one only means a few more
    /// requests, sent back to back.
    public static let maxBatchSizeLimit = 200

    public init(
        enabled: Bool = true,
        flushIntervalMs: Int = 10_000,
        flushBatchSize: Int = 30,
        maxBatchSize: Int = 200,
        queueMaxEvents: Int = 5_000,
        sessionTimeoutMs: Int = 30 * 60 * 1_000
    ) {
        self.enabled = enabled
        self.flushIntervalMs = flushIntervalMs
        self.flushBatchSize = flushBatchSize
        self.maxBatchSize = maxBatchSize
        self.queueMaxEvents = queueMaxEvents
        self.sessionTimeoutMs = sessionTimeoutMs
    }
}
