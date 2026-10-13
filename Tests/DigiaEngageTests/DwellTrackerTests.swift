import Foundation
import Testing
@testable import DigiaEngage

@MainActor
struct DwellTrackerTests {

    @Test("measures continuous dwell time when uninterrupted")
    func measuresContinuousDwellTime() {
        var currentTime: Int64 = 1000
        let tracker = DwellTracker(now: { currentTime })

        tracker.markViewed("campaign-1")
        currentTime += 3500

        #expect(tracker.elapsedMs("campaign-1") == 3500)
        #expect(tracker.consumeDwellMs("campaign-1") == 3500)
        #expect(tracker.elapsedMs("campaign-1") == nil)
    }

    @Test("excludes time spent in background across pause and resume")
    func excludesTimeSpentInBackground() {
        var currentTime: Int64 = 1000
        let tracker = DwellTracker(now: { currentTime })

        // 1. Shows in foreground for 2 seconds.
        tracker.markViewed("campaign-1")
        currentTime += 2000 // t = 3000

        // 2. App goes to background for 20 minutes (1,200,000 ms).
        tracker.pause()
        currentTime += 1_200_000 // t = 1,203,000

        // Dwell while in background reflects only elapsed foreground time.
        #expect(tracker.elapsedMs("campaign-1") == 2000)

        // 3. App returns to foreground for 3 seconds.
        tracker.resume()
        currentTime += 3000 // t = 1,206,000

        // Total foreground dwell = 2s + 3s = 5s (5000 ms).
        #expect(tracker.elapsedMs("campaign-1") == 5000)
        #expect(tracker.consumeDwellMs("campaign-1") == 5000)
        #expect(tracker.elapsedMs("campaign-1") == nil)
    }

    @Test("campaign marked viewed while app is paused starts counting only on resume")
    func marksViewedWhilePaused() {
        var currentTime: Int64 = 1000
        let tracker = DwellTracker(now: { currentTime })

        // App is backgrounded before the campaign becomes visible.
        tracker.pause()
        currentTime += 5000 // t = 6000

        // Campaign marks viewed while in background.
        tracker.markViewed("campaign-bg")
        currentTime += 10000 // t = 16000

        #expect(tracker.elapsedMs("campaign-bg") == 0)

        // App returns to foreground.
        tracker.resume()
        currentTime += 2500 // t = 18500

        #expect(tracker.elapsedMs("campaign-bg") == 2500)
        #expect(tracker.consumeDwellMs("campaign-bg") == 2500)
    }

    @Test("tracks multiple concurrent campaigns independently across lifecycle changes")
    func tracksMultipleCampaignsIndependently() {
        var currentTime: Int64 = 1000
        let tracker = DwellTracker(now: { currentTime })

        tracker.markViewed("guide-1")
        currentTime += 1000 // t = 2000

        tracker.markViewed("nudge-1")
        currentTime += 1000 // t = 3000

        tracker.pause()
        currentTime += 30000 // 30s background

        tracker.resume()
        currentTime += 1500 // 1.5s foreground

        #expect(tracker.elapsedMs("guide-1") == 3500)
        #expect(tracker.elapsedMs("nudge-1") == 2500)
    }

    @Test("idempotent pause and resume calls do not corrupt dwell calculations")
    func idempotentPauseResume() {
        var currentTime: Int64 = 1000
        let tracker = DwellTracker(now: { currentTime })

        tracker.markViewed("campaign-1")
        currentTime += 2000

        tracker.pause()
        currentTime += 5000
        tracker.pause() // redundant pause
        currentTime += 5000

        tracker.resume()
        currentTime += 1000
        tracker.resume() // redundant resume
        currentTime += 1000

        #expect(tracker.consumeDwellMs("campaign-1") == 4000)
    }

    @Test("clear resets all campaign entries")
    func clearResetsEntries() {
        let tracker = DwellTracker()
        tracker.markViewed("campaign-1")
        tracker.clear()
        #expect(tracker.elapsedMs("campaign-1") == nil)
    }
}
