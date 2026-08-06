import CoreGraphics

/// A tiny testable description of the host's blind consumption policy. The real
/// SwiftUI host renders the same three cases inline so it can keep its view tree
/// type concrete: ready draws, notReady waits, and failed is empty.
internal enum GuideOverlayRenderState: Equatable, Sendable {
    case ready
    case waiting
    case hidden
}

internal enum GuideOverlayTargetConsumer {
    internal static func renderState(_ outcome: TargetOutcome) -> GuideOverlayRenderState {
        switch outcome {
        case .ready:
            return .ready
        case .notReady:
            return .waiting
        case .failed:
            return .hidden
        }
    }
}
