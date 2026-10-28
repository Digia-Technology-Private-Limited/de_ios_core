import SwiftUI

/// A `RoundedRectangle` whose corner radius is capped at half the shorter side, as Flutter's
/// `RRect` and Compose's `RoundedCornerShape` cap it, so a server radius such as 999 draws a
/// circle or pill. SwiftUI may draw a plain `RoundedRectangle` as a `CALayer` corner radius
/// and border; Core Animation's software renderer (`CALayer.render(in:)`, used by snapshots
/// and screen captures) does not cap that radius and strokes the border's straight edges
/// past the shape. This shape is always drawn from its clamped path.
struct ClampedRoundedRectangle: Shape {
    var cornerRadius: CGFloat
    var style: RoundedCornerStyle = .circular

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(max(0, cornerRadius), min(rect.width, rect.height) / 2)
        return RoundedRectangle(cornerRadius: radius, style: style).path(in: rect)
    }
}
