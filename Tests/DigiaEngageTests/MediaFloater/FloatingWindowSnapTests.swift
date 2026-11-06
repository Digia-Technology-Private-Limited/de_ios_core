import CoreGraphics
import Testing

@testable import DigiaEngage

/// T9: where the shared floating window comes to rest after a drag, a fling or a plain release.
/// The window is 350 pt square on a 1000 pt screen with no safe area or margin, so it moves over
/// 0...650 pt on each axis and starts in the bottom-right corner (650, 650). Each test drives
/// `FloatingWindow` as the touch shield does (`dragChanged` while the finger moves, `dragEnded`
/// with the release velocity), feeds the committed fraction back as the orchestrator does, and
/// reads where the window rests: its resting rect plus what is left of the settle spring.
///
/// Same cases and names as Android's `FloatingWindowSnapTest`.
@Suite("Floating window: where a release comes to rest", .tags(.unit, .floater, .pip))
@MainActor
struct FloatingWindowSnapTests {

    private let windowSize = CGSize(width: 350, height: 350)
    private let bounds = FloatingWindowBounds(minX: 0, maxX: 650, minY: 0, maxY: 650)

    /// Drags the window from bottom-right by [drag], lets go at [velocity] pt/s, and answers the
    /// committed fraction and where the window rests.
    private func releaseAndRest(
        drag: CGSize, velocity: CGVector, snapToCorner: Bool
    ) -> (fraction: FloaterFraction?, rest: CGPoint) {
        let window = FloatingWindow()
        let start = floatingRestingRect(
            windowSize: windowSize, bounds: bounds, position: .bottomRight, dragFraction: nil)
        var committed: FloaterFraction?
        window.dragChanged(drag, draggable: true, closing: false)
        window.dragEnded(
            translation: drag, velocity: velocity, resting: start, bounds: bounds,
            draggable: true, closing: false, snapToCorner: snapToCorner,
            onCommit: { committed = $0 })
        let resting = floatingRestingRect(
            windowSize: windowSize, bounds: bounds, position: .bottomRight, dragFraction: committed)
        return (committed, CGPoint(x: resting.minX + window.delta.width, y: resting.minY + window.delta.height))
    }

    // Fails if a release stops snapping to the nearest corner: FloatingWindow.swift
    // `floatingReleaseFraction` `return (projected - min) / span >= 0.5 ? 1 : 0` -> `return 0`.
    @Test("a slow release rests in the nearest corner")
    func aSlowReleaseRestsInTheNearestCorner() {
        // Released at (250, 550): left of the middle, below it.
        let (fraction, rest) = releaseAndRest(
            drag: CGSize(width: -400, height: -100), velocity: .zero, snapToCorner: true)

        #expect(fraction == FloaterFraction(x: 0, y: 1))
        #expect(rest == CGPoint(x: 0, y: 650))
    }

    // Fails if a fling stops carrying the window on: FloatingWindow.swift `floatingReleaseFraction`
    // `: position + velocity * FloatingWindow.snapFlingProjectionSeconds` -> `: position`.
    // Released right of the middle (x 400) but flung left at 3000 pt/s, it lands left.
    @Test("a fling carries the window to the corner it was thrown toward")
    func aFlingCarriesTheWindowToTheCornerItWasThrownToward() {
        let (fraction, rest) = releaseAndRest(
            drag: CGSize(width: -250, height: 0), velocity: CGVector(dx: -3_000, dy: 0), snapToCorner: true)

        #expect(fraction == FloaterFraction(x: 0, y: 1))
        #expect(rest == CGPoint(x: 0, y: 650))
    }

    // Fails if a slow drag's tail velocity counts as a fling: FloatingWindow.swift
    // `floatingReleaseFraction` `let projected = abs(velocity) < FloatingWindow.snapFlingMinVelocity`
    // -> `let projected = false`. At 400 pt/s, under the 450 pt/s threshold, the window stays on the
    // side it was released on.
    @Test("a drag ending slower than a fling rests on the side it was released")
    func aDragEndingSlowerThanAFlingRestsOnTheSideItWasReleased() {
        // Released at x 350, just right of the middle; projected, 400 pt/s would carry it past it.
        let (fraction, rest) = releaseAndRest(
            drag: CGSize(width: -300, height: 0), velocity: CGVector(dx: -400, dy: 0), snapToCorner: true)

        #expect(fraction == FloaterFraction(x: 1, y: 1))
        #expect(rest.x == 650)
    }

    // Fails if a window that does not snap is pulled to a corner anyway: FloatingWindow.swift
    // `floatingReleaseFraction` `guard snapToCorner else {` -> `guard true else {`. It rests exactly
    // where it was let go.
    @Test("without snapping the window rests where it was let go")
    func withoutSnappingTheWindowRestsWhereItWasLetGo() {
        let (fraction, rest) = releaseAndRest(
            drag: CGSize(width: -325, height: -325), velocity: .zero, snapToCorner: false)

        #expect(fraction == FloaterFraction(x: 0.5, y: 0.5))
        #expect(rest == CGPoint(x: 325, y: 325))
    }
}
