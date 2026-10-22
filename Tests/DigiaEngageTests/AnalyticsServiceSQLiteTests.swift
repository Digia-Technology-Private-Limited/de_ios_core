import Foundation
import Testing
@testable import DigiaEngage

/// The service over the real SQLite queue, across a process restart: the path
/// production takes, which the other service tests run on a memory queue. Same
/// test on Android (`AnalyticsServiceSqliteTest`) and Flutter
/// (`analytics_service_sqlite_test.dart`).
@MainActor
@Suite("AnalyticsService over SQLite", .serialized)
struct AnalyticsServiceSQLiteTests {

    @Test("events captured offline survive a restart without using up retries, and are delivered once")
    func offlineEventsSurviveRestart() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("analytics_\(UUID().uuidString).db").path
        let defaults = UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        /// One "process": a queue that owns the file and a service over it.
        func launch(_ sender: any NetworkClient) -> (AnalyticsService, SQLiteAnalyticsQueue) {
            let queue = SQLiteAnalyticsQueue(opener: AnalyticsDatabaseOpener(resolvePath: { path }), maxEvents: 100)
            let service = makeTestAnalyticsService(
                config: AnalyticsConfig(flushIntervalMs: 600_000),
                sender: sender,
                defaults: defaults,
                queue: queue
            )
            return (service, queue)
        }

        let offline = ThrowingAnalyticsSender()
        let (first, firstQueue) = launch(offline)
        first.retryScheduleMs = [60_000]  // keep the offline retry out of the test's way
        for key in ["a", "b", "c"] {
            first.capture(NudgeEvent.Viewed(displayStyle: "dialog"), payload: testPayload(key), campaignId: key, campaignType: "nudge")
        }
        first.flush()  // no network: not counted as an attempt
        try await waitForAnalytics { offline.callCount == 1 }
        first.clear()
        await firstQueue.close()  // process death

        let online = FakeAnalyticsSender()
        let (second, secondQueue) = launch(online)
        let queued = await secondQueue.peek(maxCount: 10)
        #expect(queued.map { $0.payload["campaign_key"] as? String } == ["a", "b", "c"])
        #expect(queued.map(\.attempts) == [0, 0, 0])

        second.flush()
        try await waitForAnalytics { online.callCount == 1 && second.queue.size == 0 }

        #expect(online.callCount == 1)
        #expect(online.batches.single?.map { $0["campaign_key"] as? String } == ["a", "b", "c"])
        #expect(await secondQueue.count() == 0)
        second.clear()
        await secondQueue.close()
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
