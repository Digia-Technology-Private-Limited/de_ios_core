// Module: anchorless/solver
//
// The value vocabulary of the solver surface — native runtime contract §2 and §3.
// No platform type appears here: `FrameRect` is not `CGRect`, and
// `RuntimeGeometrySnapshot` is not a `UIWindow`. That is what makes ARCH-1 hold
// and what lets the Conformance Vectors run with no device.

// MARK: - Wire enums (§3)

/// The runtime OS. Not the app technology — that is `binding`, which lives in the
/// capture tree and never reaches the solver.
internal enum AnchorlessDevicePlatform: String, Equatable, Sendable, CaseIterable {
    case android
    case ios

    /// The logical unit this platform's variant must declare.
    internal var requiredLogicalUnit: AnchorlessLogicalUnit {
        switch self {
        case .android: return .dp
        case .ios: return .pt
        }
    }
}

internal enum AnchorlessLogicalUnit: String, Equatable, Sendable, CaseIterable {
    case dp
    case pt
}

internal enum AnchorlessMode: String, Equatable, Sendable, CaseIterable {
    case image
    case element
}

/// A frame a Reference Container may itself be measured against.
internal enum AnchorlessRootFrame: String, Equatable, Sendable, CaseIterable {
    case window
    case appContent
}

/// A frame a target axis may be measured against.
internal enum AnchorlessTargetFrame: String, Equatable, Sendable, CaseIterable {
    case window
    case appContent
    case referenceContainer
}

// MARK: - Geometry values (§2)

/// A floating-point rectangle in logical units. Used for frames and for the
/// unrounded intermediate edges the solver carries end to end.
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

/// The whole of the device state the solver is allowed to see: two frames.
///
/// `orientation`, `formFactor`, `pageKey`, and `logicalUnit` were deliberately
/// removed (§2). The prohibition on runtime semantic lookup is therefore
/// structural — the solver has nothing to consult.
internal struct RuntimeGeometrySnapshot: Equatable, Sendable {
    /// The full guide overlay window, including status bar, navigation bar and cutout.
    internal let window: FrameRect
    /// `window` minus safe-area insets, ignoring the IME, so a target never moves
    /// because a keyboard opened.
    internal let appContent: FrameRect
    internal init(
        window: FrameRect,
        appContent: FrameRect
    ) {
        self.window = window
        self.appContent = appContent
    }
}

/// The solver's only successful output: integers in logical units.
///
/// Width and height are **derived** from the rounded edges and are never rounded
/// independently (§4.5).
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

// MARK: - Rules (§3)

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

// MARK: - Crop reference (§3)

/// `AnchorlessCropRefV1`. Carried through `prepare` so `mode: "image"` can be
/// validated and so the presentation host can fetch the published crop; the solver
/// itself never reads it.
internal struct AnchorlessCropRef: Equatable, Sendable {
    internal let cropId: String
    internal let url: String
    internal let widthPx: Double
    internal let heightPx: Double
    internal let sourceScale: Double
    internal let focalX: Double
    internal let focalY: Double
}

// MARK: - Diagnostics trace (§9)

/// The closed, content-free trace value a solver result carries.
///
/// Returned with solver results so the runtime can record the outcome locally.
///
/// Every field is an enum, a number, or an authored identifier. There is no host
/// string, no captured text, and no free-form map.
internal struct AnchorlessTrace: Equatable, Sendable {
    internal let phase: AnchorlessPhase
    internal let failure: AnchorlessFailure?
    internal let variantId: String?
    internal let pageKey: String?
    internal let horizontalFrame: AnchorlessTargetFrame?
    internal let verticalFrame: AnchorlessTargetFrame?
    /// Edges before the single rounding pass, when the solver got that far.
    internal let preRoundingRect: FrameRect?
    /// Edges after rounding, when the solver got that far.
    internal let postRoundingRect: ResolvedTargetRect?

    internal init(
        phase: AnchorlessPhase,
        failure: AnchorlessFailure? = nil,
        variantId: String? = nil,
        pageKey: String? = nil,
        horizontalFrame: AnchorlessTargetFrame? = nil,
        verticalFrame: AnchorlessTargetFrame? = nil,
        preRoundingRect: FrameRect? = nil,
        postRoundingRect: ResolvedTargetRect? = nil
    ) {
        self.phase = phase
        self.failure = failure
        self.variantId = variantId
        self.pageKey = pageKey
        self.horizontalFrame = horizontalFrame
        self.verticalFrame = verticalFrame
        self.preRoundingRect = preRoundingRect
        self.postRoundingRect = postRoundingRect
    }
}
