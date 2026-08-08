// Module: capture/evidence
//
// The Production Capture Field Allowlist v1, expressed as Swift types.
//
// Capture minimization and review gate §2, and the machine-readable copy at
// `testkit/fixtures/anchorless/capture-allowlist-v1.json`.
//
// The governing rule of this file, from §2 and from item I2:
//
//     The evidence allowlist is enforced by type, not by filter.
//
// Nothing prohibited by §3 is stripped on the way out, because nothing prohibited
// by §3 is *representable* on the way in. There is no property on any type below
// that a host string could occupy, so no future edit to a walker, a serializer, or
// a transport can put one on the wire. That is the structural answer to I2: the
// POC read a secure entry field's characters into a queryable field; here there is
// no such field to read into.
//
// ARCH-2: this module names nothing in `anchorless/*`.

import Foundation

// MARK: - Wire shapes (§2.3 valueTypes)

/// `{left, top, right, bottom}` finite integers in physical pixels.
internal struct CaptureEdgeRect: Equatable, Sendable {
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
    internal var area: Int { max(0, width) * max(0, height) }
    internal var isEmpty: Bool { right <= left || bottom <= top }

    /// Empty when the two do not meet. Edge contact is not an intersection.
    internal func intersection(_ other: CaptureEdgeRect) -> CaptureEdgeRect {
        CaptureEdgeRect(
            left: max(left, other.left),
            top: max(top, other.top),
            right: min(right, other.right),
            bottom: min(bottom, other.bottom)
        )
    }
}

internal struct CaptureInsets: Equatable, Sendable {
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
}

internal struct CapturePoint: Equatable, Sendable {
    internal let x: Int
    internal let y: Int

    internal init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

internal struct CaptureSize: Equatable, Sendable {
    internal let width: Int
    internal let height: Int

    internal init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// The six finite affine components of §2.6, named rather than ordered.
///
/// `(x, y)` maps to `(a * x + c * y + tx, b * x + d * y + ty)`.
internal struct CaptureAffine: Equatable, Sendable {
    internal let a: Double
    internal let b: Double
    internal let c: Double
    internal let d: Double
    internal let tx: Double
    internal let ty: Double

    internal init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    internal static let identity = CaptureAffine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
}

// MARK: - Closed enumerations (§2 enums)

internal enum CaptureDevicePlatform: String, Equatable, Sendable, CaseIterable {
    case android
    case ios
}

internal enum CaptureBinding: String, Equatable, Sendable, CaseIterable {
    case native
    case flutter
    case reactNative
}

/// §2.3 — the Beta is portrait phones only, so `landscape` is not a member. A
/// landscape device cannot produce this enumeration and therefore cannot produce a
/// capture.
internal enum CaptureOrientation: String, Equatable, Sendable, CaseIterable {
    case portrait
}

internal enum CaptureLayoutDirection: String, Equatable, Sendable, CaseIterable {
    case ltr
    case rtl
}

/// §2.5 — likewise phones only.
internal enum CaptureFormFactor: String, Equatable, Sendable, CaseIterable {
    case phone
}

internal enum CaptureVisibilityState: String, Equatable, Sendable, CaseIterable {
    case unclipped
    case partiallyClipped
    case fullyClipped
    case offscreen
}

internal enum CaptureScrollAxis: String, Equatable, Sendable, CaseIterable {
    case horizontal
    case vertical
}

/// Coarse, content-free authoring intent category exported by capture schema v1.
internal enum CaptureNodeType: String, Equatable, Sendable, CaseIterable {
    case interactive
    case text
    case image
    case container
    case unknown
}

internal enum CaptureTruncationReason: String, Equatable, Sendable, CaseIterable {
    case nodeLimit
    case depthLimit
    case timeLimit
}

// MARK: - Closed enumerations §2.6 declares but no locked contract enumerates

// §2.6 calls `containerTraits[]`, `role`, and `supportedActions[]` closed enums and
// never names their members; neither does any other locked document, and
// `capture-allowlist-v1.json` records all three as `undecidedInLockedContracts`.
//
// Inventing members here would be a product decision this package is not entitled
// to make, so each is declared **uninhabited**. An uninhabited enumeration has no
// instances, so `[CaptureContainerTrait]` can only ever be `[]` and `CaptureRole?`
// can only ever be `nil` — which is exactly what the CV-1 fixtures expect. When the
// contracts enumerate the members, adding them here is the only change required and
// every emission site keeps compiling.

internal enum CaptureContainerTrait: Equatable, Sendable {
    internal var wireName: String { switch self {} }
}

internal enum CaptureRole: Equatable, Sendable {
    internal var wireName: String { switch self {} }
}

internal enum CaptureAction: Equatable, Sendable {
    internal var wireName: String { switch self {} }
}

// MARK: - Envelope objects

/// §2.2. The PNG travels as the multipart file part; no property here can hold it.
internal struct CaptureScreenshotFacts: Equatable, Sendable {
    /// §2.2 — a literal. JPEG is rejected, and no property selects a format.
    internal static let mimeType = "image/png"

    internal let widthPx: Int
    internal let heightPx: Int
    internal let byteLength: Int
    /// 64 lowercase hex characters, the digest of the bytes actually sent.
    internal let sha256: String

    internal init(widthPx: Int, heightPx: Int, byteLength: Int, sha256: String) {
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.byteLength = byteLength
        self.sha256 = sha256
    }
}

/// §2.3 — the capture frame.
internal struct CaptureSourceFrame: Equatable, Sendable {
    internal let density: Double
    internal let windowBoundsPx: CaptureEdgeRect
    internal let appContentBoundsPx: CaptureEdgeRect
    internal let insetsPx: CaptureInsets
    internal let orientation: CaptureOrientation
    internal let layoutDirection: CaptureLayoutDirection

    internal init(
        density: Double,
        windowBoundsPx: CaptureEdgeRect,
        appContentBoundsPx: CaptureEdgeRect,
        insetsPx: CaptureInsets,
        orientation: CaptureOrientation,
        layoutDirection: CaptureLayoutDirection
    ) {
        self.density = density
        self.windowBoundsPx = windowBoundsPx
        self.appContentBoundsPx = appContentBoundsPx
        self.insetsPx = insetsPx
        self.orientation = orientation
        self.layoutDirection = layoutDirection
    }
}

/// §2.4, iOS variant.
///
/// The Android variant is deliberately not representable in this SDK: the
/// `capturePlatformAppMismatch` rejection cannot be provoked from here because
/// there is no type that could carry the wrong shape.
internal struct CaptureAppFacts: Equatable, Sendable {
    internal let bundleIdentifier: String
    internal let versionName: String
    internal let buildNumber: String

    internal init(bundleIdentifier: String, versionName: String, buildNumber: String) {
        self.bundleIdentifier = bundleIdentifier
        self.versionName = versionName
        self.buildNumber = buildNumber
    }
}

/// §2.5. `osVersion` is the iOS `systemVersion` string.
internal struct CaptureRuntimeFacts: Equatable, Sendable {
    internal let osVersion: String
    internal let locale: String
    internal let fontScale: Double
    internal let sdkVersion: String
    /// Required when `binding` is `flutter` or `reactNative`; `nil` for `native`.
    internal let wrapperVersion: String?
    internal let formFactor: CaptureFormFactor

    internal init(
        osVersion: String,
        locale: String,
        fontScale: Double,
        sdkVersion: String,
        wrapperVersion: String?,
        formFactor: CaptureFormFactor
    ) {
        self.osVersion = osVersion
        self.locale = locale
        self.fontScale = fontScale
        self.sdkVersion = sdkVersion
        self.wrapperVersion = wrapperVersion
        self.formFactor = formFactor
    }
}

/// §2.6 — the content-free structural node. Exactly these keys, nothing else.
///
/// Read the property list once: there is no string on it except `nodeId`,
/// `parentId`, `clipContainerId` and `scrollParentId`, all four of which are
/// capture-local structural paths. Everything a host could recognise about its own
/// screen — characters, labels, identifiers, class names — is absent by
/// construction rather than by omission.
internal struct CaptureStructuralNode: Equatable, Sendable {
    // Topology
    internal let nodeId: String
    internal let parentId: String?
    internal let childIndex: Int
    internal let paintOrder: Double

    // Geometry
    internal let localBoundsPx: CaptureEdgeRect
    internal let transformToRoot: CaptureAffine
    internal let rootBoundsPx: CaptureEdgeRect
    internal let visibleBoundsPx: CaptureEdgeRect?
    internal let clipContainerId: String?
    internal let clipBoundsPx: CaptureEdgeRect?

    // Visibility
    internal let inheritedShown: Bool
    internal let effectiveAlpha: Double
    internal let visibleFraction: Double
    internal let visibilityState: CaptureVisibilityState

    // Containers
    internal let containerTraits: [CaptureContainerTrait]
    internal let scrollAxes: [CaptureScrollAxis]
    internal let viewportBoundsPx: CaptureEdgeRect?
    internal let scrollOffsetPx: CapturePoint?
    internal let contentExtentPx: CaptureSize?
    internal let scrollParentId: String?
    internal let virtualized: Bool

    // Meaning
    internal let role: CaptureRole?
    internal let supportedActions: [CaptureAction]

    // Content-free state
    internal let enabled: Bool
    internal let selected: Bool
    internal let checked: Bool?
    internal let expanded: Bool?
    internal let focused: Bool
    internal let editable: Bool
    internal let hasText: Bool
    internal let renderedLineCount: Int
    internal let hasAccessibilityLabel: Bool

    // Integrity
    internal let valid: Bool
    internal let nodeType: CaptureNodeType
}

/// §2.7. `truncated: false` with a limit hit is a rejection, not a silent success,
/// so the walker sets both together and never one without the other.
internal struct CaptureIntegrityFacts: Equatable, Sendable {
    internal let nodeCount: Int
    internal let maxDepth: Int
    internal let truncated: Bool
    internal let truncationReason: CaptureTruncationReason?

    internal init(
        nodeCount: Int,
        maxDepth: Int,
        truncated: Bool,
        truncationReason: CaptureTruncationReason?
    ) {
        self.nodeCount = nodeCount
        self.maxDepth = maxDepth
        self.truncated = truncated
        self.truncationReason = truncationReason
    }
}

/// §2.1 — the whole wire object.
internal struct PageCaptureEnvelopeV1: Equatable, Sendable {
    /// §2.1 literals. `1` is rejected by the backend; there is no POC compatibility
    /// and no property that could request one.
    internal static let captureSchemaVersion = 1

    internal let pageKey: String
    internal let capturedAt: String
    internal let devicePlatform: CaptureDevicePlatform
    internal let binding: CaptureBinding
    internal let screenshot: CaptureScreenshotFacts
    internal let source: CaptureSourceFrame
    internal let app: CaptureAppFacts
    internal let runtime: CaptureRuntimeFacts
    internal let nodes: [CaptureStructuralNode]
    internal let integrity: CaptureIntegrityFacts

    internal init(
        pageKey: String,
        capturedAt: String,
        devicePlatform: CaptureDevicePlatform,
        binding: CaptureBinding,
        screenshot: CaptureScreenshotFacts,
        source: CaptureSourceFrame,
        app: CaptureAppFacts,
        runtime: CaptureRuntimeFacts,
        nodes: [CaptureStructuralNode],
        integrity: CaptureIntegrityFacts
    ) {
        self.pageKey = pageKey
        self.capturedAt = capturedAt
        self.devicePlatform = devicePlatform
        self.binding = binding
        self.screenshot = screenshot
        self.source = source
        self.app = app
        self.runtime = runtime
        self.nodes = nodes
        self.integrity = integrity
    }
}

// MARK: - Limits (§2.7, §2.8)

internal enum CaptureLimits {
    internal static let maxNodeCount = 2_000
    internal static let maxDepth = 64
    internal static let maxCaptureJsonBytes = 524_288
    internal static let maxPngBytes = 12_582_912
}
