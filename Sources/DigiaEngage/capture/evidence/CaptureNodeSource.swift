// Module: capture/evidence
//
// What the walker is allowed to ask a host view about.
//
// This protocol is the second half of the I2 answer. `CaptureAllowlistV1` makes a
// prohibited field unrepresentable on the way *out*; this protocol makes it
// unaskable on the way *in*. There is no member here that returns a host string,
// so a walker cannot read one even by accident, and an adapter that wanted to
// hand one over would have nowhere to put it.
//
// The shape mirrors `testkit/fixtures/anchorless/cv1-synthetic-screen.json`
// exactly, which is why the CV-1 fixture can be fed to the same walker that walks
// a real UIKit hierarchy: one walker, one derivation, four stacks.
//
// Platform-free by construction — no UIKit, no CoreGraphics, no Foundation type
// crosses this boundary.

/// A scroll block. Present only on a scrolling container.
internal struct CaptureScrollFacts: Equatable, Sendable {
    internal let axes: [CaptureScrollAxis]
    internal let offsetPx: CapturePoint
    internal let contentExtentPx: CaptureSize

    internal init(axes: [CaptureScrollAxis], offsetPx: CapturePoint, contentExtentPx: CaptureSize) {
        self.axes = axes
        self.offsetPx = offsetPx
        self.contentExtentPx = contentExtentPx
    }
}

/// The nine content-free state flags of §2.6.
///
/// Every member is a `Bool` or a coarse `Int`. `hasText` says *that* a node has
/// characters; nothing here can say *which*.
internal struct CaptureNodeState: Equatable, Sendable {
    internal let enabled: Bool
    internal let selected: Bool
    internal let checked: Bool?
    internal let expanded: Bool?
    internal let focused: Bool
    internal let editable: Bool
    internal let hasText: Bool
    internal let renderedLineCount: Int
    internal let hasAccessibilityLabel: Bool

    internal init(
        enabled: Bool = true,
        selected: Bool = false,
        checked: Bool? = nil,
        expanded: Bool? = nil,
        focused: Bool = false,
        editable: Bool = false,
        hasText: Bool = false,
        renderedLineCount: Int = 0,
        hasAccessibilityLabel: Bool = false
    ) {
        self.enabled = enabled
        self.selected = selected
        self.checked = checked
        self.expanded = expanded
        self.focused = focused
        self.editable = editable
        self.hasText = hasText
        self.renderedLineCount = renderedLineCount
        self.hasAccessibilityLabel = hasAccessibilityLabel
    }

    internal static let inert = CaptureNodeState()
}

/// One host node, reduced to what §2.6 permits before the walk even begins.
///
/// Main-actor isolated because a host view hierarchy may only be read there. That
/// is an isolation requirement, not a platform dependency: no UIKit type appears
/// on this protocol, and the walker behind it does no I/O.
@MainActor
internal protocol CaptureNodeSource {
    var childNodes: [CaptureNodeSource] { get }

    /// Physical pixels. `localBoundsPx` is `{0, 0, width, height}`.
    var sizePx: CaptureSize { get }
    var transformToRoot: CaptureAffine { get }

    var shown: Bool { get }
    var ownAlpha: Double { get }
    var clipsChildren: Bool { get }
    var scroll: CaptureScrollFacts? { get }
    var virtualized: Bool { get }

    var state: CaptureNodeState { get }

    /// A Digia Engage-owned view: the capture bubble, a guide overlay, a nudge.
    ///
    /// §5 — Digia-owned overlays are excluded from both the PNG and the node walk.
    /// The walker drops the node **and its whole subtree**, so an overlay cannot
    /// contribute structure through a child either. Guarded by T-3.
    var isDigiaOwned: Bool { get }
}
