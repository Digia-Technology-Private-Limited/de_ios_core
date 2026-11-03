import Foundation
import Testing
import UIKit

@testable import DigiaEngage

// The byte-driving contract (T10): which plan action calls which warmer, and that leaving the
// window cancels in-flight work while bytes already written stay on disk. The warmer is the
// `MediaPrefetch` protocol (lane H owns the implementation); the fake below pins the routing.
// Same cases as Android's `StoryPlanDriverTest`.

private final class FakeStoryPrefetch: MediaPrefetch, @unchecked Sendable {
    private let lock = NSLock()
    private var _ranged: [(String, Int)] = []
    private var _whole: [String] = []
    private var _images: [String] = []
    private var _cancelled = 0
    var gate = false

    var ranged: [(String, Int)] { lock.withLock { _ranged } }
    var whole: [String] { lock.withLock { _whole } }
    var images: [String] { lock.withLock { _images } }
    var cancelled: Int { lock.withLock { _cancelled } }

    func warmVideoBytes(url: String, lengthBytes: Int) async -> Int {
        if gate {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            lock.withLock { _cancelled += 1 }
            return 0
        }
        lock.withLock { _ranged.append((url, lengthBytes)) }
        return lengthBytes
    }

    func warmWholeVideo(url: String) async -> Int {
        lock.withLock { _whole.append(url) }
        return 0
    }

    func enqueueImage(_ url: String) {
        lock.withLock { _images.append(url) }
    }

    func warmImage(_ url: String) async -> UIImage? { nil }

    func warmLottie(_ url: String) async -> Bool { false }
}

private func storyURL(_ index: Int) -> String { "https://media.test/\(index).mp4" }
private func storyIsVideo(_ index: Int) -> Bool { index != 7 }

private func poll(
    _ condition: @autoclosure () -> Bool,
    timeout: TimeInterval = 2
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@Suite("StoryPlanDriver", .tags(.media, .unit))
struct StoryPlanDriverTests {
    // Fails if `firstBytes` warms the wrong range: the `warmVideoBytes(url, storyFirstBytes)`
    // call in `update`.
    @Test("first bytes warms the head range only")
    func firstBytesWarmsTheHeadRangeOnly() async {
        let prefetch = FakeStoryPrefetch()
        let driver = StoryPlanDriver(prefetch: prefetch)

        driver.update(
            actions: [.firstBytes(index: 1)],
            urlOf: storyURL, isVideoOf: storyIsVideo)
        #expect(await poll(prefetch.ranged.count == 1))
        #expect(prefetch.ranged.first?.0 == storyURL(1))
        #expect(prefetch.ranged.first?.1 == storyFirstBytes)
        #expect(prefetch.whole.isEmpty)
        #expect(prefetch.images.isEmpty)
        driver.cancelAll()
    }

    // Fails if a video `wholeFile` warms a head range instead: the `warmWholeVideo(url)` call.
    @Test("a whole video file warms to the end")
    func wholeVideoFileWarmsToTheEnd() async {
        let prefetch = FakeStoryPrefetch()
        let driver = StoryPlanDriver(prefetch: prefetch)

        driver.update(
            actions: [.wholeFile(index: 1)],
            urlOf: storyURL, isVideoOf: storyIsVideo)
        #expect(await poll(prefetch.whole == [storyURL(1)]))
        #expect(prefetch.ranged.isEmpty)
        driver.cancelAll()
    }

    // Fails if an image `wholeFile` warms video bytes: the `enqueueImage(url)` call.
    @Test("a whole file image enqueues instead of warming")
    func wholeFileImageEnqueuesInsteadOfWarming() async {
        let prefetch = FakeStoryPrefetch()
        let driver = StoryPlanDriver(prefetch: prefetch)

        driver.update(
            actions: [.wholeFile(index: 7)],
            urlOf: storyURL, isVideoOf: storyIsVideo)
        // `enqueueImage` is synchronous: no wait needed.
        #expect(prefetch.images == [storyURL(7)])
        #expect(prefetch.ranged.isEmpty)
        #expect(prefetch.whole.isEmpty)
        driver.cancelAll()
    }

    // Fails if a player action warms bytes: the `.player -> break` arm in `update`.
    @Test("players do no byte work")
    func playersDoNoByteWork() async {
        let prefetch = FakeStoryPrefetch()
        let driver = StoryPlanDriver(prefetch: prefetch)

        driver.update(
            actions: [.player(index: 1, priority: .onScreen)],
            urlOf: storyURL, isVideoOf: storyIsVideo)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(prefetch.ranged.isEmpty)
        #expect(prefetch.whole.isEmpty)
        #expect(prefetch.images.isEmpty)
        driver.cancelAll()
    }

    // Fails if leaving the window does not cancel: the stale-tasks `cancel()` in `update`.
    @Test("leaving the window cancels in-flight work")
    func leavingTheWindowCancelsInFlightWork() async {
        let prefetch = FakeStoryPrefetch()
        prefetch.gate = true
        let driver = StoryPlanDriver(prefetch: prefetch)

        driver.update(
            actions: [.firstBytes(index: 1)],
            urlOf: storyURL, isVideoOf: storyIsVideo)
        driver.update(
            actions: [.firstBytes(index: 5)],
            urlOf: storyURL, isVideoOf: storyIsVideo)

        #expect(await poll(prefetch.cancelled == 1))
        driver.cancelAll()
    }

    // Fails if `cancelAll` spares jobs: the cancel loop in `cancelAll`.
    @Test("cancel all stops everything")
    func cancelAllStopsEverything() async {
        let prefetch = FakeStoryPrefetch()
        prefetch.gate = true
        let driver = StoryPlanDriver(prefetch: prefetch)

        driver.update(
            actions: [.firstBytes(index: 1), .firstBytes(index: 2)],
            urlOf: storyURL, isVideoOf: storyIsVideo)
        driver.cancelAll()

        #expect(await poll(prefetch.cancelled == 2))
    }
}
