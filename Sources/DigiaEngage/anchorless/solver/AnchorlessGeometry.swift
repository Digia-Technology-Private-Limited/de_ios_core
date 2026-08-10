import Foundation

internal enum AnchorlessDevicePlatform: String, Equatable, Sendable, CaseIterable {
    case android
    case ios
}

internal enum AnchorlessRootFrame: String, Equatable, Sendable, CaseIterable {
    case window
    case appContent
}

internal enum AnchorlessTargetFrame: String, Equatable, Sendable, CaseIterable {
    case window
    case appContent
    case referenceContainer
}

internal struct FrameRect: Equatable, Sendable {
    internal let left: Double
    internal let top: Double
    internal let right: Double
    internal let bottom: Double

    internal init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    internal var width: Double { right - left }
    internal var height: Double { bottom - top }
}

internal struct RuntimeGeometrySnapshot: Equatable, Sendable {
    internal let window: FrameRect
    internal let appContent: FrameRect
    internal init(
        window: FrameRect,
        appContent: FrameRect
    ) {
        self.window = window
        self.appContent = appContent
    }
}

internal struct ResolvedTargetRect: Equatable, Sendable {
    internal let left: Int
    internal let top: Int
    internal let right: Int
    internal let bottom: Int

    internal init(left: Int, top: Int, right: Int, bottom: Int) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    internal var width: Int { right - left }
    internal var height: Int { bottom - top }
}

internal enum AnchorlessHorizontalRule: Equatable, Sendable {
    case startFixed(startOffset: Double, width: Double)
    case endFixed(endOffset: Double, width: Double)
    case centered(width: Double)
    case stretch(startInset: Double, endInset: Double)
    case proportional(startFraction: Double, endFraction: Double)
}

internal enum AnchorlessVerticalRule: Equatable, Sendable {
    case topFixed(topOffset: Double, height: Double)
    case bottomFixed(bottomOffset: Double, height: Double)
    case centered(height: Double)
    case stretch(topInset: Double, bottomInset: Double)
    case proportional(topFraction: Double, bottomFraction: Double)
    case widthScaled(topRatio: Double, height: Double)
}

internal struct AnchorlessImage: Equatable, Sendable {
    internal let data: Data
}

internal struct AnchorlessTrace: Equatable, Sendable {
    internal let phase: AnchorlessPhase
    internal let failure: AnchorlessFailure?
    internal let assetId: String?
    internal let pageKey: String?
    internal let horizontalFrame: AnchorlessTargetFrame?
    internal let verticalFrame: AnchorlessTargetFrame?
    internal let preRoundingRect: FrameRect?
    internal let postRoundingRect: ResolvedTargetRect?

    internal init(
        phase: AnchorlessPhase,
        failure: AnchorlessFailure? = nil,
        assetId: String? = nil,
        pageKey: String? = nil,
        horizontalFrame: AnchorlessTargetFrame? = nil,
        verticalFrame: AnchorlessTargetFrame? = nil,
        preRoundingRect: FrameRect? = nil,
        postRoundingRect: ResolvedTargetRect? = nil
    ) {
        self.phase = phase
        self.failure = failure
        self.assetId = assetId
        self.pageKey = pageKey
        self.horizontalFrame = horizontalFrame
        self.verticalFrame = verticalFrame
        self.preRoundingRect = preRoundingRect
        self.postRoundingRect = postRoundingRect
    }
}
