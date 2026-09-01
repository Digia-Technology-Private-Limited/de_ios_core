import Foundation
import CoreFoundation
import CoreGraphics

/// Canvas-only placement. Distances use authored canvas units and scale with the surface.
struct NudgeCloseButtonPlacement: Equatable {
    enum Mode: String { case inside, outside }
    enum Horizontal: String { case left, center, right }
    enum Vertical: String { case top, bottom }

    let mode: Mode
    let horizontal: Horizontal
    let vertical: Vertical
    let offsetX: CGFloat
    let offsetY: CGFloat
    let gap: CGFloat

    static func fromJson(_ json: [String: Any]?) -> Self? {
        guard let json,
            let mode = Mode(rawValue: json["mode"] as? String ?? ""),
            let horizontal = Horizontal(rawValue: json["horizontal"] as? String ?? ""),
            let vertical = Vertical(rawValue: json["vertical"] as? String ?? "")
        else { return nil }
        func distance(_ key: String, fallback: CGFloat) -> CGFloat {
            guard let value = json[key] as? NSNumber,
                CFGetTypeID(value) != CFBooleanGetTypeID(),
                value.doubleValue.isFinite, value.doubleValue >= 0
            else { return fallback }
            return CGFloat(value.doubleValue)
        }
        return Self(
            mode: mode, horizontal: horizontal, vertical: vertical,
            offsetX: distance("offsetX", fallback: 0),
            offsetY: distance("offsetY", fallback: 0),
            gap: distance("gap", fallback: 12)
        )
    }

    struct Layout {
        let circle: CGRect
        let touch: CGRect
    }

    func scaled(_ factor: CGFloat) -> Self {
        let scale = factor.isFinite ? max(0, factor) : 1
        return Self(
            mode: mode,
            horizontal: horizontal,
            vertical: vertical,
            offsetX: offsetX * scale,
            offsetY: offsetY * scale,
            gap: gap * scale
        )
    }

    /// Resolve against the fitted card, then keep the entire hit region on screen.
    func layout(diameter: CGFloat, container: CGRect, safe: CGRect, isBottomSheet: Bool) -> Layout? {
        let inside = container.intersection(safe)
        guard !inside.isNull, inside.width > 0, inside.height > 0,
            diameter.isFinite, diameter > 0 else { return nil }
        let size = min(diameter, safe.width, safe.height)
        let touchWidth = min(max(size, 44), safe.width)
        let touchHeight = min(max(size, 44), safe.height)
        let edge = isBottomSheet && mode == .outside ? Vertical.top : vertical
        func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            min(max(value, lower), max(lower, upper))
        }
        func horizontalOrigin(in bounds: CGRect, offset: CGFloat, size: CGFloat) -> CGFloat {
            switch horizontal {
            case .left: return bounds.minX + offset
            case .center: return bounds.midX - size / 2
            case .right: return bounds.maxX - size - offset
            }
        }
        var circleSize = size
        var x = horizontalOrigin(in: container, offset: mode == .inside ? offsetX : 0, size: size)
        var y: CGFloat
        let availableGap = edge == .top
            ? container.minY - safe.minY - size
            : safe.maxY - container.maxY - size
        if mode == .outside && availableGap >= 0 {
            let fittedGap = min(gap, availableGap)
            y = edge == .top ? container.minY - fittedGap - size : container.maxY + fittedGap
            x = clamp(x, safe.minX, safe.maxX - size)
        } else {
            circleSize = min(size, inside.width, inside.height)
            x = horizontalOrigin(in: container, offset: mode == .inside ? offsetX : 0, size: circleSize)
            y = edge == .top
                ? container.minY + (mode == .inside ? offsetY : 0)
                : container.maxY - circleSize - (mode == .inside ? offsetY : 0)
            x = clamp(x, inside.minX, inside.maxX - circleSize)
            y = clamp(y, inside.minY, inside.maxY - circleSize)
        }
        let circle = CGRect(x: x, y: y, width: circleSize, height: circleSize)
        let preferredTouchY = mode == .outside && availableGap >= 0
            ? (edge == .top ? circle.maxY - touchHeight : circle.minY)
            : circle.midY - touchHeight / 2
        return Layout(
            circle: circle,
            touch: CGRect(
                x: clamp(circle.midX - touchWidth / 2, safe.minX, safe.maxX - touchWidth),
                y: clamp(preferredTouchY, safe.minY, safe.maxY - touchHeight),
                width: touchWidth, height: touchHeight
            )
        )
    }
}
