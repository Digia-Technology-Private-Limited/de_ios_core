import UIKit

@MainActor
public final class AnchorRegistry: ObservableObject {
    public static let shared = AnchorRegistry()
    private init() {}

    /// Bumped whenever anchors change so observing views (e.g. the guide overlay)
    /// re-resolve anchor rects when an anchor registers after a guide has started.
    @Published public private(set) var version = 0

    private var viewRegistry: [String: WeakBox] = [:]
    private var rectRegistry: [String: CGRect] = [:]
    private var cornerRadii: [String: CGFloat] = [:]

    public func register(key: String, view: UIView, cornerRadius: CGFloat = 0) {
        viewRegistry[key] = WeakBox(view)
        cornerRadii[key] = cornerRadius
        version &+= 1
    }

    public func register(key: String, rect: CGRect, cornerRadius: CGFloat = 0) {
        rectRegistry[key] = rect
        cornerRadii[key] = cornerRadius
        version &+= 1
    }

    public func unregister(key: String) {
        viewRegistry.removeValue(forKey: key)
        rectRegistry.removeValue(forKey: key)
        cornerRadii.removeValue(forKey: key)
        version &+= 1
    }

    public func getView(for key: String) -> UIView? {
        return viewRegistry[key]?.value
    }

    public func getRect(for key: String) -> CGRect? {
        if let rect = rectRegistry[key] { return rect }
        return viewRegistry[key]?.value.map { $0.convert($0.bounds, to: nil) }
    }

    public func getCornerRadius(for key: String) -> CGFloat {
        return cornerRadii[key] ?? 0
    }
}

private final class WeakBox {
    weak var value: UIView?
    init(_ value: UIView) { self.value = value }
}
