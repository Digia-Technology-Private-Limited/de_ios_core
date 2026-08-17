import Foundation

internal struct CaptureEdgeRect: Equatable, Sendable {
    internal let left: Int
    internal let top: Int
    internal let right: Int
    internal let bottom: Int

    internal var width: Int { right - left }
    internal var height: Int { bottom - top }
    internal var isEmpty: Bool { right <= left || bottom <= top }

    internal func intersection(_ other: CaptureEdgeRect) -> CaptureEdgeRect? {
        let value = CaptureEdgeRect(
            left: max(left, other.left),
            top: max(top, other.top),
            right: min(right, other.right),
            bottom: min(bottom, other.bottom)
        )
        return value.isEmpty ? nil : value
    }
}

internal struct CaptureSize: Equatable, Sendable {
    internal let width: Int
    internal let height: Int
}

internal enum CaptureDevicePlatform: String, Equatable, Sendable {
    case ios
}

internal enum CaptureOrientation: String, Equatable, Sendable {
    case portrait
}

internal enum CaptureLayoutDirection: String, Equatable, Sendable {
    case ltr
}

internal enum CaptureNodeType: String, Equatable, Sendable {
    case interactive
    case text
    case image
    case container
    case unknown
}

internal enum CaptureScrollAxis: String, Equatable, Sendable {
    case horizontal
    case vertical
    case both
}

internal struct CaptureProfile: Equatable, Sendable {
    internal let includeText: Bool
    internal let includeImagesAndMedia: Bool
    internal let includeOtherStructuralNodes: Bool

    internal static let minimal = CaptureProfile(
        includeText: false,
        includeImagesAndMedia: false,
        includeOtherStructuralNodes: false
    )
}

internal struct CaptureTraversalFacts: Equatable, Sendable {
    internal let elapsedMs: Double
    internal let visitedNodeCount: Int
    internal let capturedNodeCount: Int
}

internal struct CaptureSourceFrame: Equatable, Sendable {
    internal let density: Double
    internal let windowBoundsPx: CaptureEdgeRect
    internal let appContentBoundsPx: CaptureEdgeRect
    internal let orientation: CaptureOrientation
    internal let layoutDirection: CaptureLayoutDirection
}

internal struct CaptureStructuralNode: Equatable, Sendable {
    internal let nodeId: String
    internal let parentId: String?
    internal let childIndex: Int
    internal let rootBoundsPx: CaptureEdgeRect
    internal let fullyVisible: Bool
    internal let nodeType: CaptureNodeType
    internal let scrollAxis: CaptureScrollAxis?
}

internal struct PageCaptureEnvelopeV1: Equatable, Sendable {
    internal static let captureSchemaVersion = 1

    internal let pageKey: String
    internal let binding: String
    internal let devicePlatform: CaptureDevicePlatform
    internal let source: CaptureSourceFrame
    internal let screenshotSizePx: CaptureSize
    internal let appVersion: String
    internal let appBuildNumber: String
    internal let sdkVersion: String
    internal let profile: CaptureProfile
    internal let traversal: CaptureTraversalFacts
    internal let nodes: [CaptureStructuralNode]
}
