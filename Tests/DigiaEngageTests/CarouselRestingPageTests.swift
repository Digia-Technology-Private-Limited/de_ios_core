import CoreGraphics
import Testing
@testable import DigiaEngage

/// Pins `carouselRestingPage`, which decides whether a stopped carousel strip
/// needs a snap and which page autoplay advances from.
@Suite("Carousel resting page")
struct CarouselRestingPageTests {
    @Test("a strip on a page is aligned on that page")
    func onPage() {
        let resting = carouselRestingPage(offset: 2 * 400, stride: 400, pageCount: 6)
        #expect(resting.page == 2)
        #expect(resting.aligned)
    }

    @Test("a strip stopped mid-slide is unaligned and resolves to the nearer page")
    func midSlide() {
        let behind = carouselRestingPage(offset: 400 + 150, stride: 400, pageCount: 6)
        #expect(behind.page == 1)
        #expect(!behind.aligned)
        let ahead = carouselRestingPage(offset: 400 + 250, stride: 400, pageCount: 6)
        #expect(ahead.page == 2)
        #expect(!ahead.aligned)
    }

    @Test("sub-point rounding still counts as on the page")
    func subPointRounding() {
        #expect(carouselRestingPage(offset: 800.4, stride: 400, pageCount: 6).aligned)
    }

    @Test("a strip pulled past either end reads as the end page")
    func pastEnds() {
        #expect(carouselRestingPage(offset: -120, stride: 400, pageCount: 6).page == 0)
        #expect(carouselRestingPage(offset: 5 * 400 + 160, stride: 400, pageCount: 6).page == 5)
    }

    @Test("degenerate input reads as resting on the first page")
    func degenerate() {
        for resting in [
            carouselRestingPage(offset: 300, stride: 0, pageCount: 6),
            carouselRestingPage(offset: .nan, stride: 400, pageCount: 6),
            carouselRestingPage(offset: 300, stride: 400, pageCount: 0),
        ] {
            #expect(resting.page == 0)
            #expect(resting.aligned)
        }
    }
    // Three slides with two clones a side: [c c s0 s1 s2 c c], pages 0...6.

    @Test("autoplay on a looping strip steps onto the trailing clone, then wraps to the first real page")
    func autoPlayWrapsOffTrailingClone() {
        #expect(carouselAutoPlayNextPage(current: 4, displayCount: 7, loopClones: 2, loopEnabled: true) == 5)
        #expect(carouselAutoPlayNextPage(current: 6, displayCount: 7, loopClones: 2, loopEnabled: true) == 2)
    }

    @Test("autoplay on a finite strip stops on its last page")
    func autoPlayStopsAtFiniteEnd() {
        #expect(carouselAutoPlayNextPage(current: 1, displayCount: 3, loopClones: 0, loopEnabled: false) == 2)
        #expect(carouselAutoPlayNextPage(current: 2, displayCount: 3, loopClones: 0, loopEnabled: false) == nil)
    }

    @Test("a clone's twin is the same slide one lap away")
    func loopTwin() {
        #expect(carouselLoopTwin(page: 0, slideCount: 3, loopClones: 2) == 3)
        #expect(carouselLoopTwin(page: 1, slideCount: 3, loopClones: 2) == 4)
        #expect(carouselLoopTwin(page: 5, slideCount: 3, loopClones: 2) == 2)
        #expect(carouselLoopTwin(page: 6, slideCount: 3, loopClones: 2) == 3)
    }
}
