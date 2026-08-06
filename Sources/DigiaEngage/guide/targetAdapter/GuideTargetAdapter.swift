// Module: guide/targetAdapter
//
// One surface serves both target modes, so Anchorless never leaks into a
// presentation host. Native runtime contract §8:
//
//     resolveTarget(step) -> Ready(rect, cornerRadius) | NotReady | Failed(code)
//
// The adapter owns one `TargetOutcome` for **both** Registered Anchor and
// Anchorless. It must not own knowing which mode produced the rectangle, clipping,
// or fallback between modes.
//
// ARCH-3: no presentation-host type is imported here. The host consumes
// `TargetOutcome`; this module never names the host. Wiring into `GuideOverlayView`
// is wired into the iOS host through the same blind-consumption surface.

import CoreGraphics

/// The single outcome a presentation host reads. It carries a rectangle and a
/// corner radius and nothing that says how they were produced.
internal enum TargetOutcome: Equatable, Sendable {
    case ready(rect: CGRect, cornerRadius: CGFloat)

    /// A Registered Anchor that has not yet been measured.
    ///
    /// **An Anchorless target never returns this** — it resolves once from a
    /// snapshot and has no tracking session.
    case notReady

    /// Fail closed. The code is `nil` only for the codeless runtime state
    /// documented on `AnchorlessRuntimeOutcome.unavailable`; no fourteenth
    /// `AnchorlessFailure` code is invented to fill it.
    case failed(AnchorlessFailure?)
}

/// What a single guide step says about its target.
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

/// The seam onto the existing anchor registry. Injected as a value so the adapter
/// is testable with no host and no registry. The host never reads this seam.
@MainActor
internal protocol RegisteredAnchorSource {
    /// `nil` when the anchor has not been measured yet.
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
            case let .resolved(rect, _):
                return .ready(rect: Self.cgRect(from: rect), cornerRadius: step.cornerRadius)
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
