import Foundation
import CoreFoundation
import CoreGraphics

/// Inside rectangles use normalized artwork coordinates; outside gaps use screen points.
struct NudgeCloseButtonPlacement: Equatable {
    enum Mode: String { case inside, outside }
    enum Horizontal: String { case left, center, right }
    enum Vertical: String { case top, bottom }

    var mode: Mode { rect == nil ? .outside : .inside }
    let horizontal: Horizontal
    let vertical: Vertical
    let gap: CGFloat
    var rect: CGRect? = nil

    static func fromJson(_ json: [String: Any]?) -> Self? {
        if let json {
            let values = ["x", "y", "width", "height"].compactMap { key -> CGFloat? in
                guard let number = json[key] as? NSNumber,
                    CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
                return CGFloat(number.doubleValue)
            }
            if values.count == 4, values[2] > 0, values[3] > 0 {
                return Self(horizontal: .left, vertical: .top, gap: 12,
                    rect: CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
            }
        }
        return nil
    }

    static func fromCloseJson(_ json: [String: Any]) -> Self? {
        if let placement = json["placement"] as? [String: Any] { return fromJson(placement) }
        guard json["placement"] is NSNull else { return nil }
        let snap = json["outsidePlacement"] as? [String: Any] ?? [:]
        guard let horizontal = Horizontal(rawValue: snap["horizontal"] as? String ?? "right"),
            let vertical = Vertical(rawValue: snap["vertical"] as? String ?? "top")
        else { return nil }
        let gap: CGFloat
        if let value = snap["gap"] as? NSNumber,
            CFGetTypeID(value) != CFBooleanGetTypeID(),
            value.doubleValue.isFinite, value.doubleValue >= 0 {
            gap = CGFloat(value.doubleValue)
        } else {
            gap = 12
        }
        return Self(horizontal: horizontal, vertical: vertical, gap: gap)
    }

    func forCanvas(source: CGSize, target: CGSize) -> Self {
        guard let rect, source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return self }
        let width = rect.width * source.width
        let height = rect.height * source.height
        func axis(_ position: CGFloat, _ size: CGFloat, _ from: CGFloat, _ to: CGFloat) -> CGFloat {
            let endGap = from - position - size
            return min(max(0, position <= endGap ? position : to - endGap - size), max(0, to - size))
        }
        var result = self
        result.rect = CGRect(
            x: axis(rect.minX * source.width, width, source.width, target.width) / target.width,
            y: axis(rect.minY * source.height, height, source.height, target.height) / target.height,
            width: width / target.width, height: height / target.height)
        return result
    }

    struct Layout {
        let circle: CGRect
        let touch: CGRect
    }

    /// Resolve against the fitted card, then keep the entire hit region on screen.
    func layout(diameter: CGFloat, container: CGRect, safe: CGRect, isBottomSheet: Bool) -> Layout? {
        if let rect {
            let size = max(0, min(rect.width * container.width, rect.height * container.height, safe.width, safe.height))
            func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
                min(max(value, lower), max(lower, upper))
            }
            let circle = CGRect(
                x: clamp(container.minX + rect.minX * container.width, safe.minX, safe.maxX - size),
                y: clamp(container.minY + rect.minY * container.height, safe.minY, safe.maxY - size),
                width: size, height: size)
            let width = min(max(size, 44), safe.width)
            let height = min(max(size, 44), safe.height)
            return Layout(circle: circle, touch: CGRect(
                x: clamp(circle.midX - width / 2, safe.minX, safe.maxX - width),
                y: clamp(circle.midY - height / 2, safe.minY, safe.maxY - height),
                width: width, height: height))
        }
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
        func horizontalOrigin(in bounds: CGRect, size: CGFloat) -> CGFloat {
            switch horizontal {
            case .left: return bounds.minX
            case .center: return bounds.midX - size / 2
            case .right: return bounds.maxX - size
            }
        }
        var circleSize = size
        var x = horizontalOrigin(in: container, size: size)
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
            x = horizontalOrigin(in: container, size: circleSize)
            y = edge == .top
                ? container.minY
                : container.maxY - circleSize
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
