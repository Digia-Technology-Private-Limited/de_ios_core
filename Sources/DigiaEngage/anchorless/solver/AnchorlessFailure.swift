// Module: anchorless/solver
//
// The failure contract — native runtime contract §5. One enum, thirteen codes,
// three disjoint subsets, identical on every stack.
//
// Every code fails closed: no impression, no dismissal, no completion, no
// user-visible error, one local trace. There is never a fallback to Registered
// Anchor or any other mode.

/// The phase that owns a failure.
internal enum AnchorlessPhase: String, Equatable, Sendable, CaseIterable {
    /// `anchorless/solver`, at delivery time, with no device state.
    case prepare
    /// `anchorless/runtime`, after `prepare` and before `resolve`.
    case gate
    /// `anchorless/solver`, against a live snapshot.
    case resolve
}

/// The thirteen Anchorless failure codes.
///
/// The raw values are the wire spellings used by
/// `testkit/contracts/anchorless-solver-vectors.json`.
internal enum AnchorlessFailure: String, Equatable, Sendable, CaseIterable {
    // MARK: prepare — owned by anchorless/solver

    case unknownTargetType
    case unknownTargetVersion
    case unknownRuleKind
    case invalidModel
    case stepCountInvalid
    case missingPlatformVariant
    case danglingReferenceContainer

    // MARK: eligibility gate — owned by anchorless/runtime

    case pageKeyMismatch
    case unsupportedOrientation
    case unsupportedFormFactor

    // MARK: resolve — owned by anchorless/solver

    case nonPositiveRect
    case rectOutsideFrame

    /// The phase subset this code belongs to. The three subsets are disjoint and
    /// exhaustive over the thirteen codes.
    internal var phase: AnchorlessPhase {
        switch self {
        case .unknownTargetType, .unknownTargetVersion, .unknownRuleKind, .invalidModel,
             .stepCountInvalid, .missingPlatformVariant, .danglingReferenceContainer:
            return .prepare
        case .pageKeyMismatch, .unsupportedOrientation, .unsupportedFormFactor:
            return .gate
        case .nonPositiveRect, .rectOutsideFrame:
            return .resolve
        }
    }
}
