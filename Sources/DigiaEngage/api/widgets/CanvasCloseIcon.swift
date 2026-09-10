import SwiftUI

/// Matches the dashboard's Lucide X in a 24-unit viewBox.
struct CanvasCloseIcon: View {
    let size: CGFloat

    var body: some View {
        CanvasCloseShape()
            .stroke(style: StrokeStyle(lineWidth: size * 2.5 / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct CanvasCloseShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.75, y: rect.minY + rect.height * 0.25))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.75))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.25))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.75, y: rect.minY + rect.height * 0.75))
        return path
    }
}
