import Foundation
import Testing
@testable import DigiaEngage

@Suite("Separate canvas close rect")
struct CanvasCloseRectTests {
    @Test func nearestEdgeAndFinalFit() throws {
        let placement = try #require(NudgeCloseButtonPlacement.fromCloseJson([
            "placement": ["x": 0.8, "y": 0.1, "width": 0.1, "height": 0.06]
        ])).forCanvas(source: CGSize(width: 360, height: 600), target: CGSize(width: 360, height: 400))
        let layout = try #require(placement.layout(
            diameter: 36, container: CGRect(x: 20, y: 100, width: 180, height: 200),
            safe: CGRect(x: 0, y: 0, width: 400, height: 800), isBottomSheet: true))
        #expect(abs(layout.circle.minX - 164) < 0.001)
        #expect(abs(layout.circle.minY - 130) < 0.001)
        #expect(abs(layout.circle.width - 18) < 0.001)
        #expect(layout.touch.size == CGSize(width: 44, height: 44))
    }

    @Test func outsideNullAndSafeFallback() throws {
        let placement = try #require(NudgeCloseButtonPlacement.fromCloseJson([
            "placement": NSNull(),
            "outsidePlacement": ["horizontal": "center", "vertical": "bottom", "gap": 12]
        ]))
        #expect(placement.mode == .outside)
        let layout = try #require(placement.layout(
            diameter: 26, container: CGRect(x: 0, y: 10, width: 360, height: 390),
            safe: CGRect(x: 0, y: 0, width: 360, height: 400), isBottomSheet: true))
        #expect(layout.circle.minY == 10)
        #expect(layout.touch.minY >= 0)
        #expect(layout.touch.maxY <= 400)
    }

    @Test func outsideUsesDialogChromeClearanceWithoutWindowSafeInset() throws {
        let placement = try #require(NudgeCloseButtonPlacement.fromCloseJson([
            "placement": NSNull(),
            "outsidePlacement": ["horizontal": "right", "vertical": "top", "gap": 12]
        ]))
        let layout = try #require(placement.layout(
            diameter: 26, container: CGRect(x: 16, y: 56, width: 368, height: 500),
            safe: CGRect(x: 0, y: 0, width: 400, height: 766), isBottomSheet: false))
        #expect(layout.circle.maxY == 44)
        #expect(layout.circle.maxY < 56)
        #expect(layout.touch.minY >= 0)
    }

    @Test func malformedRectIsRejected() {
        #expect(NudgeCloseButtonPlacement.fromCloseJson([
            "placement": ["x": true, "y": 0, "width": 0.1, "height": 0.1]
        ]) == nil)
        #expect(NudgeCloseButtonPlacement.fromCloseJson([
            "placement": ["x": 0, "y": 0, "width": 0, "height": 0.1]
        ]) == nil)
    }
}
