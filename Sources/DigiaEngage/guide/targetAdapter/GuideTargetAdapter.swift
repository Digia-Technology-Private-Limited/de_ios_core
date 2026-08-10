import CoreGraphics

internal enum TargetOutcome: Equatable, Sendable {
    case ready(rect: CGRect, cornerRadius: CGFloat, image: AnchorlessImage? = nil)

    case notReady
    case failed(AnchorlessFailure?)
}

internal enum GuideTargetSpec: Equatable, Sendable {
    case registeredAnchor(anchorKey: String)
    case anchorless(target: AnchorlessJSONValue)
}

internal struct GuideTargetStep: Sendable {
    internal let spec: GuideTargetSpec
    internal let cornerRadius: CGFloat

    internal init(spec: GuideTargetSpec, cornerRadius: CGFloat) {
        self.spec = spec
        self.cornerRadius = cornerRadius
    }
}

internal struct RegisteredAnchorMeasurement: Equatable, Sendable {
    internal let rect: CGRect
    internal let cornerRadius: CGFloat

    internal init(rect: CGRect, cornerRadius: CGFloat) {
        self.rect = rect
        self.cornerRadius = cornerRadius
    }
}

@MainActor
internal protocol RegisteredAnchorSource {
    func target(forAnchorKey anchorKey: String) -> RegisteredAnchorMeasurement?
}

@MainActor
internal struct GuideTargetAdapter {
    private let anchorSource: RegisteredAnchorSource
    private let anchorlessRuntime: AnchorlessRuntime

    internal init(anchorSource: RegisteredAnchorSource, anchorlessRuntime: AnchorlessRuntime) {
        self.anchorSource = anchorSource
        self.anchorlessRuntime = anchorlessRuntime
    }

    internal func resolveTarget(_ step: GuideTargetStep) -> TargetOutcome {
        switch step.spec {
        case let .registeredAnchor(anchorKey):
            guard let measurement = anchorSource.target(forAnchorKey: anchorKey) else { return .notReady }
            return .ready(rect: measurement.rect, cornerRadius: measurement.cornerRadius)

        case let .anchorless(target):
            switch anchorlessRuntime.resolve(target: target) {
            case let .resolved(rect, prepared):
                return .ready(
                    rect: Self.cgRect(from: rect),
                    cornerRadius: step.cornerRadius,
                    image: prepared.image
                )
            case let .failed(failure):
                return .failed(failure)
            case .unavailable:
                return .failed(nil)
            }
        }
    }

    /// iOS logical units are points, so the integers cross unchanged. Highlight
    /// padding is applied by the host after acceptance and never participates in
    /// validation, so none is added here.
    internal static func cgRect(from rect: ResolvedTargetRect) -> CGRect {
        CGRect(
            x: CGFloat(rect.left),
            y: CGFloat(rect.top),
            width: CGFloat(rect.width),
            height: CGFloat(rect.height)
        )
    }
}
