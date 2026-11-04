import Foundation
import Testing
@testable import DigiaEngage

/// The extracted floating window's pure rules: size, resting rect, snap.
/// Port-adjacent: mirrors the Android `FloatingWindow` commit/snap arithmetic; iOS asserts
/// through the same `floatingRestingRect` / `FloatingWindow.dragEnded` the session views use.
@Suite("Floating window: resting rect and snap", .tags(.unit, .media, .floater, .pip))
@MainActor
struct FloatingWindowTests {

    private var safe: FloatingWindowInsets {
        FloatingWindowInsets(.init(top: 59, leading: 0, bottom: 34, trailing: 0))
    }

    // Fails if: FloatingWindow.swift `FloatingWindowSize.height`
    // `if let fixedHeightDp { return fixedHeightDp }` -> `if let fixedHeightDp { return width / ratio }`.
    @Test("video aspect: an explicit height wins over the media ratio")
    func explicitHeightWins() {
        let rect = floatingRestingRect(
            size: .videoAspect(widthFraction: 0.55, aspectRatio: 1.78, fixedHeightDp: 240),
            screenSize: CGSize(width: 400, height: 800),
            safeInsets: safe,
            margin: FloaterMargin(left: 16, top: 16, right: 16, bottom: 16),
            position: .bottomRight,
            dragFraction: nil
        )
        #expect(rect.height == 240)
        #expect(abs(rect.width - 220) < 0.001)
    }

    // Fails if: FloatingWindow.swift `FloatingWindowSize.height`
    // `let ratio = aspectRatio > 0 ? aspectRatio : 0.5625` -> `let ratio = aspectRatio`.
    @Test("video aspect: a zero ratio falls back to 9:16, never divides by zero")
    func zeroRatioFallsBack() {
        let rect = floatingRestingRect(
            size: .videoAspect(widthFraction: 0.5, aspectRatio: 0, fixedHeightDp: nil),
            screenSize: CGSize(width: 400, height: 800),
            safeInsets: safe,
            margin: FloaterMargin(left: 0, top: 0, right: 0, bottom: 0),
            position: .topLeft,
            dragFraction: nil
        )
        #expect(abs(rect.height - 200 / 0.5625) < 0.001)
    }

    // Fails if: FloatingWindow.swift `floatingRestingRect`
    // `left = position.isRight ? maxX : minX` -> `left = maxX`.
    @Test("configured size: the corner decides the resting spot without a drag fraction")
    func cornerDecidesRestingSpot() {
        let size = FloatingWindowSize.configured(widthFraction: 0.32, aspectRatio: 0.72)
        let topLeft = floatingRestingRect(
            size: size, screenSize: CGSize(width: 400, height: 800), safeInsets: safe,
            margin: FloaterMargin(left: 16, top: 16, right: 16, bottom: 16),
            position: .topLeft, dragFraction: nil
        )
        #expect(topLeft.minX == 16)
        #expect(topLeft.minY == 75)
        #expect(abs(topLeft.height - 128 / 0.72) < 0.001)
    }

    // Fails if: FloatingWindow.swift `floatingRestingRect`
    // `if let drag = dragFraction {` gains a `, false` (the corner always wins).
    @Test("a committed drag fraction overrides the configured corner")
    func dragFractionOverridesCorner() {
        let size = FloatingWindowSize.configured(widthFraction: 0.32, aspectRatio: 0.72)
        let rect = floatingRestingRect(
            size: size, screenSize: CGSize(width: 400, height: 800), safeInsets: safe,
            margin: FloaterMargin(left: 16, top: 16, right: 16, bottom: 16),
            position: .topLeft, dragFraction: FloaterFraction(x: 1, y: 1)
        )
        let width = 400 * 0.32
        #expect(abs(rect.maxX - (400 - 16)) < 0.001)
        #expect(abs(rect.minX - (400 - 16 - width)) < 0.001)
    }

    // Fails if: FloatingWindow.swift `FloatingWindow.dragEnded`
    // `let projectedLeft = resting.minX + predictedEndTranslation.width` ->
    // `let projectedLeft = resting.minX + translation.width` (release point, not the fling).
    @Test("snap: a fling toward the far corner commits there, not at the release point")
    func snapFlingCommitsProjectedCorner() {
        let window = FloatingWindow()
        let screen = CGSize(width: 400, height: 800)
        let resting = floatingRestingRect(
            size: .videoAspect(widthFraction: 0.5, aspectRatio: 1, fixedHeightDp: nil),
            screenSize: screen, safeInsets: safe,
            margin: FloaterMargin(left: 16, top: 16, right: 16, bottom: 16),
            position: .topLeft, dragFraction: nil
        )
        window.dragChanged(CGSize(width: 30, height: 30))
        var committed: FloaterFraction?
        window.dragEnded(
            translation: CGSize(width: 30, height: 30),
            predictedEndTranslation: CGSize(width: 300, height: 300),
            resting: resting, screenSize: screen, safeInsets: safe,
            margin: FloaterMargin(left: 16, top: 16, right: 16, bottom: 16),
            draggable: true, snapToCorner: true,
            onCommit: { committed = $0 }
        )
        #expect(committed == FloaterFraction(x: 1, y: 1))
    }

    // Fails if: FloatingWindow.swift `FloatingWindow.dragEnded`
    // `var fx: CGFloat = spanX <= 0 ? 0 : floatingClamped((visualLeft - minX) / spanX, 0, 1)` ->
    // `var fx: CGFloat = 0`.
    @Test("free drop: without snap the window commits where the finger left it")
    func freeDropCommitsReleasePoint() throws {
        let window = FloatingWindow()
        let screen = CGSize(width: 400, height: 800)
        let resting = floatingRestingRect(
            size: .videoAspect(widthFraction: 0.5, aspectRatio: 1, fixedHeightDp: nil),
            screenSize: screen, safeInsets: safe,
            margin: FloaterMargin(left: 16, top: 16, right: 16, bottom: 16),
            position: .topLeft, dragFraction: nil
        )
        window.dragChanged(CGSize(width: 90, height: 40))
        var committed: FloaterFraction?
        window.dragEnded(
            translation: CGSize(width: 90, height: 40),
            predictedEndTranslation: CGSize(width: 90, height: 40),
            resting: resting, screenSize: screen, safeInsets: safe,
            margin: FloaterMargin(left: 16, top: 16, right: 16, bottom: 16),
            draggable: true, snapToCorner: false,
            onCommit: { committed = $0 }
        )
        let fraction = try #require(committed)
        #expect(fraction.x > 0.4 && fraction.x < 0.6)
        #expect(fraction.y > 0 && fraction.y < 0.2)
    }

    // Fails if: FloatingWindowHeroTransition.swift `floaterStoryWindowAlpha`
    // `min(max((0.5 - t) * 4, 0), 1)` -> `min(max((0.75 - t) * 4, 0), 1)`.
    @Test("hero handoff: the window stays opaque until the aperture is opaque, then fades")
    func heroHandoffOrder() {
        #expect(floaterStoryHeroAlpha(type: .hero, phase: 0.25) == 1)
        #expect(floaterStoryWindowAlpha(type: .hero, phase: 0.25) == 1)
        #expect(floaterStoryWindowAlpha(type: .hero, phase: 0.5) == 0)
        #expect(floaterStoryHeroAlpha(type: .hero, phase: 1) == 1)
    }
}
