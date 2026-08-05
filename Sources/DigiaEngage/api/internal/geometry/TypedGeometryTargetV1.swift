import CoreGraphics
import Foundation

struct TypedGeometryTargetV1: Equatable {
    let pageKey: String
    let model: TargetGeometryModelV1

    static func fromJson(_ json: [String: Any]?) -> TypedGeometryTargetV1? {
        guard let json, json["type"] as? String == "geometry",
              (json["version"] as? NSNumber)?.intValue == 1,
              let pageKey = (json["pageKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pageKey.isEmpty,
              json["orientation"] as? String == "portrait",
              let source = json["source"] as? [String: Any],
              let density = finitePositive(source["density"]),
              let window = bounds(source["windowBoundsPx"]),
              let content = bounds(source["appContentBoundsPx"]),
              window.contains(content),
              let direction = source["layoutDirection"] as? String,
              direction == "ltr" || direction == "rtl",
              let rectJson = json["rectPx"] as? [String: Any],
              let x = finite(rectJson["x"]), let y = finite(rectJson["y"]),
              let width = finitePositive(rectJson["width"]),
              let height = finitePositive(rectJson["height"]),
              let constraints = json["constraints"] as? [String: Any],
              let frameRaw = constraints["frame"] as? String,
              let frame = GeometryFrameV1(rawValue: frameRaw), frame != .referenceContainer,
              let horizontalRaw = constraints["horizontal"] as? String,
              let verticalRaw = constraints["vertical"] as? String
        else { return nil }

        let sourceFrame = frame == .window ? window : content
        let rect = EdgeRectV1(left: x, top: y, right: x + width, bottom: y + height)
        guard sourceFrame.contains(rect),
              let horizontal = horizontalRule(
                horizontalRaw, rect: rect, frame: sourceFrame, density: density, rtl: direction == "rtl"
              ),
              let vertical = verticalRule(
                verticalRaw, rect: rect, frame: sourceFrame, density: density
              )
        else { return nil }

        return TypedGeometryTargetV1(
            pageKey: pageKey,
            model: TargetGeometryModelV1(
                horizontal: HorizontalAxisModelV1(frame: frame, rule: horizontal),
                vertical: VerticalAxisModelV1(frame: frame, rule: vertical)
            )
        )
    }

    func resolve(snapshot: RuntimeGeometrySnapshotV1) -> CGRect? {
        guard snapshot.snapshotVersion == 1,
              snapshot.platform == .ios,
              snapshot.pageKey == pageKey,
              snapshot.orientation == "portrait",
              snapshot.formFactor == "phone",
              snapshot.density.isFinite, snapshot.density > 0,
              let window = snapshot.windowBoundsPx,
              let content = snapshot.appContentBoundsPx,
              window.contains(content),
              snapshot.layoutDirection == "ltr" || snapshot.layoutDirection == "rtl",
              let physical = AssistedGeometryRuntimeV1.resolveGeometryModel(
                model,
                window: window,
                content: content,
                density: snapshot.density,
                rtl: snapshot.layoutDirection == "rtl"
              )
        else { return nil }
        return CGRect(
            x: physical.left / snapshot.density,
            y: physical.top / snapshot.density,
            width: physical.width / snapshot.density,
            height: physical.height / snapshot.density
        )
    }

    private static func horizontalRule(
        _ kind: String, rect: EdgeRectV1, frame: EdgeRectV1, density: Double, rtl: Bool
    ) -> HorizontalRuleV1? {
        let start = (rtl ? frame.right - rect.right : rect.left - frame.left) / density
        let end = (rtl ? rect.left - frame.left : frame.right - rect.right) / density
        let width = rect.width / density
        switch kind {
        case "startFixed": return .startFixed(startOffset: start, width: width)
        case "endFixed": return .endFixed(endOffset: end, width: width)
        case "centerFixed":
            return .centerFixed(
                centerOffset: (rect.left + rect.right - frame.left - frame.right) / 2 / density,
                width: width
            )
        case "stretch": return .stretch(startInset: start, endInset: end)
        case "proportional":
            let startFraction = (rtl ? frame.right - rect.right : rect.left - frame.left) / frame.width
            let endFraction = (rtl ? frame.right - rect.left : rect.right - frame.left) / frame.width
            return .proportional(
                startFraction: startFraction,
                endFraction: endFraction
            )
        default: return nil
        }
    }

    private static func verticalRule(
        _ kind: String, rect: EdgeRectV1, frame: EdgeRectV1, density: Double
    ) -> VerticalRuleV1? {
        let top = (rect.top - frame.top) / density
        let bottom = (frame.bottom - rect.bottom) / density
        let height = rect.height / density
        switch kind {
        case "topFixed": return .topFixed(topOffset: top, height: height)
        case "bottomFixed": return .bottomFixed(bottomOffset: bottom, height: height)
        case "centerFixed":
            return .centerFixed(
                centerOffset: (rect.top + rect.bottom - frame.top - frame.bottom) / 2 / density,
                height: height
            )
        case "stretch": return .stretch(topInset: top, bottomInset: bottom)
        case "proportional":
            let topFraction = (rect.top - frame.top) / frame.height
            let bottomFraction = (rect.bottom - frame.top) / frame.height
            return .proportional(
                topFraction: topFraction,
                bottomFraction: bottomFraction
            )
        default: return nil
        }
    }

    private static func bounds(_ value: Any?) -> EdgeRectV1? {
        guard let json = value as? [String: Any],
              let left = finite(json["left"]), let top = finite(json["top"]),
              let right = finite(json["right"]), let bottom = finite(json["bottom"])
        else { return nil }
        let result = EdgeRectV1(left: left, top: top, right: right, bottom: bottom)
        return result.isFinitePositive ? result : nil
    }

    private static func finite(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func finitePositive(_ value: Any?) -> Double? {
        guard let result = finite(value), result > 0 else { return nil }
        return result
    }
}
