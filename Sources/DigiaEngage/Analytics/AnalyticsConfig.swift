import Foundation

public struct AnalyticsConfig: Sendable, Equatable {
    public let enabled: Bool
    public let flushIntervalMs: Int
    public let flushBatchSize: Int
    public let maxBatchSize: Int
    public let queueMaxEvents: Int
    public let sessionTimeoutMs: Int

    public init(
        enabled: Bool = true,
        flushIntervalMs: Int = 30_000,
        flushBatchSize: Int = 50,
        maxBatchSize: Int = 100,
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
