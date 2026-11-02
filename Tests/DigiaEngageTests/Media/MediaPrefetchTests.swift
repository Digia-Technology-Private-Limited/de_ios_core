import Foundation
import Testing
import UIKit

@testable import DigiaEngage

// Locks the W1 stub contract lane D codes against: every method answers "nothing to show"
// without throwing, so floating surfaces can warm-then-show through `MediaPrefetch` before
// the real implementation lands in T12. Each test names the production line it pins.
@Suite("Media prefetch stub", .tags(.media, .unit))
struct MediaPrefetchTests {
    private let stub: any MediaPrefetch = NoopMediaPrefetch()

    // Fails if the stub stops answering empty: the `nil`/`0`/`false` bodies in NoopMediaPrefetch.
    @Test("the stub warms nothing and answers empty")
    func stubAnswersEmpty() async {
        #expect(await stub.warmImage("https://cdn.example.com/a.png") == nil)
        #expect(await stub.warmVideoBytes(url: "https://cdn.example.com/a.mp4", lengthBytes: 512) == 0)
        #expect(await stub.warmWholeVideo(url: "https://cdn.example.com/a.mp4") == 0)
        #expect(await stub.warmLottie("https://cdn.example.com/a.json") == false)
    }

    // Fails if the fire-and-forget half grows a failure mode: the empty `enqueueImage` body.
    @Test("enqueueing never throws, even for blank urls")
    func enqueueNeverThrows() {
        stub.enqueueImage("https://cdn.example.com/a.png")
        stub.enqueueImage("")
        stub.enqueueImage("{{asset}}")
    }

    // Fails if a blank or templated URL stops being a no-op contract: the stub answers empty
    // for those too (the real implementation keeps this guard; see MediaPrefetch docs).
    @Test("blank urls answer empty without throwing")
    func blankURLsAnswerEmpty() async {
        #expect(await stub.warmImage("") == nil)
        #expect(await stub.warmImage("{{asset}}") == nil)
        #expect(await stub.warmLottie("") == false)
    }
}
