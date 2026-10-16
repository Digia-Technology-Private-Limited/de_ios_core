import Foundation
import Testing
@testable import DigiaEngage

/// Queue behavior that exists only on iOS. Everything shared with Android and
/// Flutter is in `SQLiteAnalyticsQueueTests`.
@Suite("SQLiteAnalyticsQueue (iOS)", .serialized)
struct SQLiteAnalyticsQueueIOSTests {

    /// iOS's queue (like Android's) answers `size` without waiting for its
    /// worker, counting appends not yet written. Flutter has no synchronous size.
    @Test("size is exact the moment append returns")
    func sizeCountsPendingAppends() async {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("analytics_\(UUID().uuidString).db").path
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        let queue = SQLiteAnalyticsQueue(opener: AnalyticsDatabaseOpener(resolvePath: { path }))
        for i in 0..<20 {
            queue.append(QueueEntry(eventId: "e\(i)", payload: ["event_id": "e\(i)"], createdAt: 1_000, attempts: 0), maxEvents: 100)
        }
        #expect(queue.size == 20)
        #expect(await queue.count() == 20)
        await queue.close()
    }
}
