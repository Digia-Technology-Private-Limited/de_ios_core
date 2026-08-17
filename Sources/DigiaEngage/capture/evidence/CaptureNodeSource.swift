@MainActor
internal protocol CaptureNodeSource {
    var childNodes: [CaptureNodeSource] { get }
    var rootBounds: CaptureEdgeRect { get }
    var shown: Bool { get }
    var alpha: Double { get }
    var nodeType: CaptureNodeType { get }
    var scrollAxis: CaptureScrollAxis? { get }
}
