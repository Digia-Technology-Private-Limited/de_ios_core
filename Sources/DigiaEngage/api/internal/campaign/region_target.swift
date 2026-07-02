import CoreGraphics
import Foundation

struct RegionFrac: Equatable { let x: CGFloat; let y: CGFloat; let w: CGFloat; let h: CGFloat }

struct RegionTarget: Equatable {
    let screenId: String
    let orientation: String
    let deviceClass: String
    let regionFrac: RegionFrac
    let highlightShape: String
    let highlightPadding: CGFloat

    static func fromJson(_ target: [String: Any], _ highlight: [String: Any]?) -> RegionTarget? {
        guard let screenId = target["screenId"] as? String, !screenId.isEmpty else { return nil }
        guard let f = target["regionFrac"] as? [String: Any],
              let x = (f["x"] as? NSNumber)?.doubleValue,
              let y = (f["y"] as? NSNumber)?.doubleValue,
              let w = (f["w"] as? NSNumber)?.doubleValue,
              let h = (f["h"] as? NSNumber)?.doubleValue else { return nil }
        return RegionTarget(
            screenId: screenId,
            orientation: target["orientation"] as? String ?? "portrait",
            deviceClass: target["deviceClass"] as? String ?? "phone",
            regionFrac: RegionFrac(x: CGFloat(x), y: CGFloat(y), w: CGFloat(w), h: CGFloat(h)),
            highlightShape: (highlight?["shape"] as? String) ?? "pill",
            highlightPadding: CGFloat((highlight?["padding"] as? NSNumber)?.doubleValue ?? 12)
        )
    }
}
