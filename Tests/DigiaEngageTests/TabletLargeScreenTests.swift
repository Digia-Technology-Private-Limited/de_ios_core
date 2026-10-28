import SwiftUI
@testable import DigiaEngage
import Testing

@Suite("Tablet and foldable large-screen layout")
struct TabletLargeScreenTests {
    // MARK: - isLargeScreen (pins large_screen.swift isLargeScreen)

    @Test("phones are not a large screen in either orientation")
    func phonesAreNotLargeScreen() {
        #expect(!isLargeScreen(shortestSide: 390, horizontalSizeClass: .compact))
        #expect(!isLargeScreen(shortestSide: 430, horizontalSizeClass: .compact))
        #expect(!isLargeScreen(shortestSide: 430, horizontalSizeClass: nil))
    }

    @Test("tablets reach the 600pt shortest-side breakpoint")
    func tabletsAreLargeScreen() {
        #expect(isLargeScreen(shortestSide: 600, horizontalSizeClass: .compact))
        #expect(isLargeScreen(shortestSide: 768, horizontalSizeClass: .compact))
        #expect(!isLargeScreen(shortestSide: 599, horizontalSizeClass: .compact))
    }

    @Test("regular width counts as large even below the breakpoint")
    func regularWidthIsLargeScreen() {
        #expect(isLargeScreen(shortestSide: 400, horizontalSizeClass: .regular))
    }

    // MARK: - nudgeSheetWidth (pins large_screen.swift nudgeSheetWidth)

    @Test("phone sheets keep the full screen width")
    func phoneSheetKeepsFullWidth() {
        #expect(nudgeSheetWidth(screenWidth: 390, designWidth: 360, largeScreen: false) == 390)
    }

    @Test("tablet sheets stop at 1.15x the design width")
    func tabletSheetStopsAtDialogWidth() {
        #expect(abs(nudgeSheetWidth(screenWidth: 1024, designWidth: 360, largeScreen: true) - 414) < 0.001)
    }

    @Test("tablet sheets keep the full width when the screen is narrower than the cap")
    func tabletSheetKeepsNarrowWidth() {
        #expect(nudgeSheetWidth(screenWidth: 400, designWidth: 360, largeScreen: true) == 400)
    }

    // MARK: - fullScreenCanvasScale (pins large_screen.swift fullScreenCanvasScale)

    @Test("phone full-screen canvases cover the viewport")
    func phoneCanvasCoversViewport() {
        let exact = fullScreenCanvasScale(
            authoredWidth: 360, authoredHeight: 640,
            viewportScale: 2,
            availableWidth: 720, availableHeight: 1280,
            largeScreen: false
        )
        #expect(abs(exact - 2) < 0.001)

        let tall = fullScreenCanvasScale(
            authoredWidth: 360, authoredHeight: 640,
            viewportScale: 2,
            availableWidth: 720, availableHeight: 2000,
            largeScreen: false
        )
        #expect(abs(tall - 2000 / 640) < 0.001)
    }

    @Test("tablet full-screen canvases fit whole at the dialog cap")
    func tabletCanvasFitsWhole() {
        // iPad 1024x768 against designWidth 360: the viewport scale (2.84)
        // caps at 1.15 and the canvas fits inside both dimensions.
        let fitted = fullScreenCanvasScale(
            authoredWidth: 360, authoredHeight: 640,
            viewportScale: 1024 / 360,
            availableWidth: 1024, availableHeight: 768,
            largeScreen: true
        )
        #expect(abs(fitted - 1.15) < 0.001)

        // A canvas taller than the window scales down until it fits whole.
        let shrunk = fullScreenCanvasScale(
            authoredWidth: 360, authoredHeight: 800,
            viewportScale: 1024 / 360,
            availableWidth: 1024, availableHeight: 500,
            largeScreen: true
        )
        #expect(abs(shrunk - 1.15 * (500 / (800 * 1.15))) < 0.001)
    }

    @Test("degenerate scales degrade to cover instead of vanishing")
    func degenerateScaleDegradesToCover() {
        let fallback = fullScreenCanvasScale(
            authoredWidth: 360, authoredHeight: 640,
            viewportScale: 0,
            availableWidth: 720, availableHeight: 1280,
            largeScreen: true
        )
        #expect(abs(fallback - 2) < 0.001)
    }

    // MARK: - unscaledHostScale (pins CampaignCanvasStripViews.swift unscaledHostScale)

    @Test("host scale reads back the drawn scale")
    func hostScaleReadsDrawnScale() {
        #expect(unscaledHostScale(globalWidth: 800, localWidth: 400) == 2)
        #expect(unscaledHostScale(globalWidth: 390, localWidth: 390) == 1)
    }

    @Test("degenerate host widths degrade to the unscaled layout")
    func degenerateHostScaleDegradesToOne() {
        #expect(unscaledHostScale(globalWidth: 100, localWidth: 0) == 1)
        #expect(unscaledHostScale(globalWidth: 0, localWidth: 100) == 1)
    }
}
