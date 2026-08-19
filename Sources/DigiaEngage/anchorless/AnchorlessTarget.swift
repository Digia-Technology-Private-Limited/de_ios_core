import UIKit

enum AnchorlessFailure: String, Error, Equatable {
    case invalidTarget
    case pageKeyMismatch
    case unsupportedLayout
    case invalidGeometry
}

struct AnchorlessTarget: Equatable {
    let pageKey: String
    let imageURL: URL
    private let placement: AnchorlessPlacement
    private let referenceContainer: AnchorlessPlacement?

    static func decode(_ data: Data) -> AnchorlessTarget? {
        guard let wire = try? JSONDecoder().decode(AnchorlessTargetWire.self, from: data),
              wire.type == "anchorless",
              wire.version == 1,
              !wire.hasVariants,
              let pageKey = nonEmptyString(wire.pageKey),
              let imageURLString = nonEmptyString(wire.imageUrl),
              let imageURL = URL(string: imageURLString),
              imageURL.scheme?.lowercased() == "https",
              imageURL.host?.isEmpty == false,
              let placement = AnchorlessPlacement.fromWire(wire.placement)
        else { return nil }

        let referenceContainer = wire.referenceContainer.flatMap {
            AnchorlessPlacement.fromWire($0, isReferenceContainer: true)
        }
        guard (wire.referenceContainer == nil) == (referenceContainer == nil) else { return nil }
        let usesReference = placement.horizontal.frame == .referenceContainer
            || placement.vertical.frame == .referenceContainer
        guard usesReference == (referenceContainer != nil) else { return nil }

        return AnchorlessTarget(
            pageKey: pageKey,
            imageURL: imageURL,
            placement: placement,
            referenceContainer: referenceContainer
        )
    }

    @MainActor
    func resolve(currentPageKey: String?, window: UIWindow) -> Result<CGRect, AnchorlessFailure> {
        guard currentPageKey == pageKey else { return .failure(.pageKeyMismatch) }
        // Geometry is expressed in the app window's local coordinate space. UIKit
        // normally reports a zero-origin bounds rect, but preserving a custom
        // bounds origin would diverge from Flutter's origin-zero window frame and
        // shift every anchorless target in the overlay.
        let bounds = CGRect(origin: .zero, size: window.bounds.size)
        guard bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.width < bounds.height,
              min(bounds.width, bounds.height) < 600,
              window.effectiveUserInterfaceLayoutDirection == .leftToRight
        else { return .failure(.unsupportedLayout) }

        let safeInsets = window.safeAreaInsets
        guard safeInsets.top.isFinite,
              safeInsets.left.isFinite,
              safeInsets.bottom.isFinite,
              safeInsets.right.isFinite,
              safeInsets.top >= 0,
              safeInsets.left >= 0,
              safeInsets.bottom >= 0,
              safeInsets.right >= 0
        else { return .failure(.invalidGeometry) }
        let leftInset = min(safeInsets.left, bounds.width)
        let topInset = min(safeInsets.top, bounds.height)
        let rightInset = min(safeInsets.right, bounds.width - leftInset)
        let bottomInset = min(safeInsets.bottom, bounds.height - topInset)
        let frames = AnchorlessFrames(
            window: bounds,
            appContent: CGRect(
                x: leftInset,
                y: topInset,
                width: max(0, bounds.width - leftInset - rightInset),
                height: max(0, bounds.height - topInset - bottomInset)
            ),
            referenceContainer: nil
        )
        let referenceRect = referenceContainer?.resolve(in: frames, roundEdges: false)
        if referenceContainer != nil, referenceRect == nil {
            return .failure(.invalidGeometry)
        }
        guard let rect = placement.resolve(
            in: AnchorlessFrames(
                window: frames.window,
                appContent: frames.appContent,
                referenceContainer: referenceRect
            ),
            roundEdges: true
        ), bounds.contains(rect)
        else { return .failure(.invalidGeometry) }
        return .success(rect)
    }
}

private enum AnchorlessFrame: String, Equatable {
    case window
    case appContent
    case referenceContainer
}

private struct AnchorlessFrames {
    let window: CGRect
    let appContent: CGRect
    let referenceContainer: CGRect?

    func rect(for frame: AnchorlessFrame) -> CGRect? {
        switch frame {
        case .window: return window
        case .appContent: return appContent
        case .referenceContainer: return referenceContainer
        }
    }
}

private struct AnchorlessPlacement: Equatable {
    let horizontal: AnchorlessAxisPlacement
    let vertical: AnchorlessAxisPlacement

    static func fromWire(
        _ wire: AnchorlessPlacementWire,
        isReferenceContainer: Bool = false
    ) -> AnchorlessPlacement? {
        guard let horizontal = AnchorlessAxisPlacement.fromWire(
                wire.horizontal,
                axis: .horizontal,
                isReferenceContainer: isReferenceContainer
              ),
              let vertical = AnchorlessAxisPlacement.fromWire(
                wire.vertical,
                axis: .vertical,
                isReferenceContainer: isReferenceContainer
              )
        else { return nil }
        return AnchorlessPlacement(horizontal: horizontal, vertical: vertical)
    }

    func resolve(in frames: AnchorlessFrames, roundEdges: Bool) -> CGRect? {
        guard let horizontalFrame = frames.rect(for: horizontal.frame),
              let verticalFrame = frames.rect(for: vertical.frame),
              let horizontalSpan = horizontal.rule.resolve(
                extent: horizontalFrame.width,
                crossExtent: horizontalFrame.height
              ),
              let verticalSpan = vertical.rule.resolve(
                extent: verticalFrame.height,
                crossExtent: verticalFrame.width
              )
        else { return nil }

        var rect = CGRect(
            x: horizontalFrame.minX + horizontalSpan.lowerBound,
            y: verticalFrame.minY + verticalSpan.lowerBound,
            width: horizontalSpan.upperBound - horizontalSpan.lowerBound,
            height: verticalSpan.upperBound - verticalSpan.lowerBound
        )
        guard rect.width > 0,
              rect.height > 0,
              horizontalFrame.minX <= rect.minX,
              rect.maxX <= horizontalFrame.maxX,
              verticalFrame.minY <= rect.minY,
              rect.maxY <= verticalFrame.maxY
        else { return nil }

        if roundEdges {
            let left = rect.minX.rounded()
            let top = rect.minY.rounded()
            let right = rect.maxX.rounded()
            let bottom = rect.maxY.rounded()
            rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            guard rect.width > 0,
                  rect.height > 0,
                  horizontalFrame.minX <= rect.minX,
                  rect.maxX <= horizontalFrame.maxX,
                  verticalFrame.minY <= rect.minY,
                  rect.maxY <= verticalFrame.maxY
            else { return nil }
        }
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }
}

private enum AnchorlessAxis {
    case horizontal
    case vertical
}

private struct AnchorlessAxisPlacement: Equatable {
    let frame: AnchorlessFrame
    let rule: AnchorlessAxisRule

    static func fromWire(
        _ wire: AnchorlessAxisWire,
        axis: AnchorlessAxis,
        isReferenceContainer: Bool
    ) -> AnchorlessAxisPlacement? {
        guard let frame = AnchorlessFrame(rawValue: wire.frame),
              !(isReferenceContainer && frame == .referenceContainer),
              let rule = AnchorlessAxisRule.fromWire(wire.rule, axis: axis)
        else { return nil }
        return AnchorlessAxisPlacement(frame: frame, rule: rule)
    }
}

private enum AnchorlessAxisRule: Equatable {
    case nearFixed(offset: CGFloat, size: CGFloat)
    case farFixed(offset: CGFloat, size: CGFloat)
    case centered(size: CGFloat)
    case stretch(nearInset: CGFloat, farInset: CGFloat)
    case proportional(nearFraction: CGFloat, farFraction: CGFloat)
    case widthScaled(topRatio: CGFloat, height: CGFloat)

    static func fromWire(_ wire: AnchorlessRuleWire, axis: AnchorlessAxis) -> AnchorlessAxisRule? {
        let rule: AnchorlessAxisRule?
        switch (wire.kind, axis) {
        case ("startFixed", .horizontal):
            rule = pair(wire.startOffset, wire.width).map {
                .nearFixed(offset: $0.0, size: $0.1)
            }
        case ("endFixed", .horizontal):
            rule = pair(wire.endOffset, wire.width).map {
                .farFixed(offset: $0.0, size: $0.1)
            }
        case ("topFixed", .vertical):
            rule = pair(wire.topOffset, wire.height).map {
                .nearFixed(offset: $0.0, size: $0.1)
            }
        case ("bottomFixed", .vertical):
            rule = pair(wire.bottomOffset, wire.height).map {
                .farFixed(offset: $0.0, size: $0.1)
            }
        case ("centered", .horizontal):
            rule = wire.width.map { .centered(size: CGFloat($0)) }
        case ("centered", .vertical):
            rule = wire.height.map { .centered(size: CGFloat($0)) }
        case ("stretch", .horizontal):
            rule = pair(wire.startInset, wire.endInset).map {
                .stretch(nearInset: $0.0, farInset: $0.1)
            }
        case ("stretch", .vertical):
            rule = pair(wire.topInset, wire.bottomInset).map {
                .stretch(nearInset: $0.0, farInset: $0.1)
            }
        case ("proportional", .horizontal):
            rule = pair(wire.startFraction, wire.endFraction).map {
                .proportional(nearFraction: $0.0, farFraction: $0.1)
            }
        case ("proportional", .vertical):
            rule = pair(wire.topFraction, wire.bottomFraction).map {
                .proportional(nearFraction: $0.0, farFraction: $0.1)
            }
        case ("widthScaled", .vertical):
            rule = pair(wire.topRatio, wire.height).map {
                .widthScaled(topRatio: $0.0, height: $0.1)
            }
        default:
            rule = nil
        }
        return rule?.isValid == true ? rule : nil
    }

    private var isValid: Bool {
        switch self {
        case let .nearFixed(offset, size), let .farFixed(offset, size):
            return offset >= 0 && size > 0
        case let .centered(size):
            return size > 0
        case let .stretch(nearInset, farInset):
            return nearInset >= 0 && farInset >= 0
        case let .proportional(nearFraction, farFraction):
            return nearFraction >= 0 && nearFraction < farFraction && farFraction <= 1
        case let .widthScaled(topRatio, height):
            return topRatio >= 0 && height > 0
        }
    }

    func resolve(extent: CGFloat, crossExtent: CGFloat) -> ClosedRange<CGFloat>? {
        let span: ClosedRange<CGFloat>
        switch self {
        case let .nearFixed(offset, size): span = offset...(offset + size)
        case let .farFixed(offset, size): span = (extent - offset - size)...(extent - offset)
        case let .centered(size): span = ((extent - size) / 2)...((extent + size) / 2)
        case let .stretch(nearInset, farInset): span = nearInset...(extent - farInset)
        case let .proportional(nearFraction, farFraction):
            span = (nearFraction * extent)...(farFraction * extent)
        case let .widthScaled(topRatio, height):
            let top = topRatio * crossExtent
            span = top...(top + height)
        }
        guard span.lowerBound.isFinite,
              span.upperBound.isFinite,
              span.lowerBound >= 0,
              span.lowerBound < span.upperBound,
              span.upperBound <= extent
        else { return nil }
        return span
    }
}

private struct AnchorlessTargetWire: Decodable {
    let type: String
    let version: Int
    let pageKey: String
    let imageUrl: String
    let horizontal: AnchorlessAxisWire
    let vertical: AnchorlessAxisWire
    let referenceContainer: AnchorlessPlacementWire?
    let hasVariants: Bool

    var placement: AnchorlessPlacementWire {
        AnchorlessPlacementWire(horizontal: horizontal, vertical: vertical)
    }

    private enum CodingKeys: String, CodingKey {
        case type, version, pageKey, imageUrl, horizontal, vertical, referenceContainer, variants
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        version = try values.decode(Int.self, forKey: .version)
        pageKey = try values.decode(String.self, forKey: .pageKey)
        imageUrl = try values.decode(String.self, forKey: .imageUrl)
        horizontal = try values.decode(AnchorlessAxisWire.self, forKey: .horizontal)
        vertical = try values.decode(AnchorlessAxisWire.self, forKey: .vertical)
        referenceContainer = try values.decodeIfPresent(
            AnchorlessPlacementWire.self,
            forKey: .referenceContainer
        )
        hasVariants = values.contains(.variants)
    }
}

private struct AnchorlessPlacementWire: Decodable {
    let horizontal: AnchorlessAxisWire
    let vertical: AnchorlessAxisWire
}

private struct AnchorlessAxisWire: Decodable {
    let frame: String
    let rule: AnchorlessRuleWire
}

private struct AnchorlessRuleWire: Decodable {
    let kind: String
    let startOffset: Double?
    let endOffset: Double?
    let topOffset: Double?
    let bottomOffset: Double?
    let width: Double?
    let height: Double?
    let startInset: Double?
    let endInset: Double?
    let topInset: Double?
    let bottomInset: Double?
    let startFraction: Double?
    let endFraction: Double?
    let topFraction: Double?
    let bottomFraction: Double?
    let topRatio: Double?
}

private func pair(_ first: Double?, _ second: Double?) -> (CGFloat, CGFloat)? {
    guard let first, let second, first.isFinite, second.isFinite else { return nil }
    return (CGFloat(first), CGFloat(second))
}

private func nonEmptyString(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
