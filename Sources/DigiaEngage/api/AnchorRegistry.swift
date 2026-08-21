import Combine
import UIKit

enum AnchorUnavailableReason: String, Equatable {
    case detached
    case hidden
    case invalidGeometry = "invalid_geometry"
    case outsideViewport = "outside_viewport"
    case notReadyTimeout = "not_ready_timeout"
}

enum AnchorResolution: Equatable {
    case available(CGRect)
    case missing
    case unavailable(AnchorUnavailableReason)
}

enum AnchorGeometry {
    static func resolve(
        rect: CGRect,
        viewport: CGRect,
        isAttached: Bool,
        isVisible: Bool
    ) -> AnchorResolution {
        guard isAttached else { return .unavailable(.detached) }
        guard isVisible else { return .unavailable(.hidden) }
        guard rect.isFiniteAndPositive, viewport.isFiniteAndPositive else {
            return .unavailable(.invalidGeometry)
        }
        let intersection = rect.intersection(viewport)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return .unavailable(.outsideViewport)
        }
        return .available(rect)
    }

    static func resolveActive(
        modelRect: CGRect,
        presentationRect: CGRect?,
        viewport: CGRect,
        isAttached: Bool,
        isVisible: Bool
    ) -> AnchorResolution {
        let model = resolve(
            rect: modelRect,
            viewport: viewport,
            isAttached: isAttached,
            isVisible: isVisible
        )
        guard let presentationRect else { return model }
        let presentation = resolve(
            rect: presentationRect,
            viewport: viewport,
            isAttached: isAttached,
            isVisible: isVisible
        )
        return presentation == .unavailable(.invalidGeometry) ? model : presentation
    }
}

@MainActor
public final class AnchorRegistry: NSObject, ObservableObject {
    public static let shared = AnchorRegistry()

    /// Bumped whenever anchors change so observing views re-resolve their target.
    @Published public private(set) var version = 0

    private var viewRegistry: [String: WeakBox] = [:]
    private var rectRegistry: [String: CGRect] = [:]
    private var trackedRects: [String: CGRect] = [:]
    private var cornerRadii: [String: CGFloat] = [:]
    private var activeKey: String?
    private var activeUnavailable: ((String, AnchorUnavailableReason) -> Void)?
    private var displayLink: CADisplayLink?
    private var readinessTask: Task<Void, Never>?

    private override init() {
        super.init()
    }

    public func register(key: String, view: UIView, cornerRadius: CGFloat = 0) {
        viewRegistry[key] = WeakBox(view)
        rectRegistry.removeValue(forKey: key)
        trackedRects.removeValue(forKey: key)
        cornerRadii[key] = cornerRadius
        version &+= 1
        SDKInstance.shared.recordAnchorSeen(key)
        guard activeKey == key else { return }
        readinessTask?.cancel()
        readinessTask = nil
        sampleActiveAnchor()
        startDisplayLinkIfNeeded()
    }

    public func register(key: String, rect: CGRect, cornerRadius: CGFloat = 0) {
        rectRegistry[key] = rect
        viewRegistry.removeValue(forKey: key)
        trackedRects.removeValue(forKey: key)
        cornerRadii[key] = cornerRadius
        version &+= 1
        SDKInstance.shared.recordAnchorSeen(key)
        guard activeKey == key else { return }
        readinessTask?.cancel()
        readinessTask = nil
        validateStaticRect(key: key)
    }

    public func unregister(key: String) {
        remove(key: key)
    }

    public func unregister(key: String, view: UIView) {
        guard viewRegistry[key]?.value === view else { return }
        remove(key: key)
    }

    private func remove(key: String) {
        guard viewRegistry[key] != nil || rectRegistry[key] != nil else { return }
        viewRegistry.removeValue(forKey: key)
        rectRegistry.removeValue(forKey: key)
        trackedRects.removeValue(forKey: key)
        cornerRadii.removeValue(forKey: key)
        version &+= 1
        if activeKey == key {
            failActiveAnchor(key: key, reason: .detached)
        }
    }

    public func getView(for key: String) -> UIView? {
        viewRegistry[key]?.value
    }

    public func getRect(for key: String) -> CGRect? {
        if let rect = trackedRects[key] { return rect }
        if let view = viewRegistry[key]?.value {
            return view.window.map { view.convert(view.bounds, to: $0) }
        }
        return rectRegistry[key]
    }

    public func getCornerRadius(for key: String) -> CGFloat {
        cornerRadii[key] ?? 0
    }

    public func find(_ key: String) -> CGRect? {
        getRect(for: key)
    }

    func resolution(for key: String) -> AnchorResolution {
        if let view = viewRegistry[key]?.value {
            return resolve(view: view)
        }
        if viewRegistry[key] != nil {
            return .unavailable(.detached)
        }
        guard let rect = rectRegistry[key] else { return .missing }
        guard let window = ViewControllerUtil.keyWindow() else {
            return .unavailable(.detached)
        }
        return AnchorGeometry.resolve(
            rect: rect,
            viewport: window.bounds,
            isAttached: true,
            isVisible: true
        )
    }

    func track(
        key: String?,
        waitForRegistration: Bool,
        onUnavailable: @escaping (String, AnchorUnavailableReason) -> Void
    ) {
        stopTracking()
        guard let key else { return }
        activeKey = key
        activeUnavailable = onUnavailable
        DigiaLog.verbose("[NativeGuide] stage=anchor_track_start anchor_key=\(key)")

        if viewRegistry[key] != nil {
            sampleActiveAnchor()
            startDisplayLinkIfNeeded()
        } else if rectRegistry[key] != nil {
            validateStaticRect(key: key)
        } else if waitForRegistration {
            readinessTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self, self.activeKey == key else { return }
                self.failActiveAnchor(key: key, reason: .notReadyTimeout)
            }
        } else {
            failActiveAnchor(key: key, reason: .detached)
        }
    }

    func stopTracking() {
        if let activeKey {
            DigiaLog.verbose("[NativeGuide] stage=anchor_track_stop anchor_key=\(activeKey)")
            trackedRects.removeValue(forKey: activeKey)
        }
        displayLink?.invalidate()
        displayLink = nil
        readinessTask?.cancel()
        readinessTask = nil
        activeKey = nil
        activeUnavailable = nil
    }

    func sampleActiveAnchorForTesting() {
        sampleActiveAnchor()
    }

    func resetForTesting() {
        stopTracking()
        viewRegistry.removeAll()
        rectRegistry.removeAll()
        trackedRects.removeAll()
        cornerRadii.removeAll()
        version &+= 1
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil,
              let activeKey,
              viewRegistry[activeKey]?.value?.window != nil
        else { return }
        let link = CADisplayLink(target: self, selector: #selector(sampleActiveAnchor))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func sampleActiveAnchor() {
        guard let key = activeKey else { return }
        guard let view = viewRegistry[key]?.value else {
            failActiveAnchor(key: key, reason: .detached)
            return
        }
        switch resolve(view: view) {
        case let .available(rect):
            if trackedRects[key].map({ approximatelyEqual($0, rect) }) != true {
                trackedRects[key] = rect
                version &+= 1
            }
        case let .unavailable(reason):
            failActiveAnchor(key: key, reason: reason)
        case .missing:
            break
        }
    }

    private func resolve(view: UIView) -> AnchorResolution {
        guard let window = view.window else { return .unavailable(.detached) }
        let visible = isVisible(view)
        let modelRect = view.convert(view.bounds, to: window)
        let destinationLayer = window.layer.presentation() ?? window.layer
        let presentationRect = view.layer.presentation().map {
            $0.convert($0.bounds, to: destinationLayer)
        }
        return AnchorGeometry.resolveActive(
            modelRect: modelRect,
            presentationRect: presentationRect,
            viewport: window.bounds,
            isAttached: true,
            isVisible: visible
        )
    }

    private func validateStaticRect(key: String) {
        switch resolution(for: key) {
        case .available:
            break
        case let .unavailable(reason):
            failActiveAnchor(key: key, reason: reason)
        case .missing:
            failActiveAnchor(key: key, reason: .detached)
        }
    }

    private func failActiveAnchor(key: String, reason: AnchorUnavailableReason) {
        guard activeKey == key else { return }
        let callback = activeUnavailable
        DigiaLog.verbose(
            "[NativeGuide] stage=anchor_track_drop anchor_key=\(key) reason=\(reason.rawValue)"
        )
        stopTracking()
        callback?(key, reason)
    }

    private func isVisible(_ view: UIView) -> Bool {
        var candidate: UIView? = view
        while let current = candidate {
            let opacity = current.layer.presentation()?.opacity ?? current.layer.opacity
            if current.isHidden || opacity <= 0 { return false }
            candidate = current.superview
        }
        return true
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.05
            && abs(lhs.origin.y - rhs.origin.y) < 0.05
            && abs(lhs.size.width - rhs.size.width) < 0.05
            && abs(lhs.size.height - rhs.size.height) < 0.05
    }
}

private final class WeakBox {
    weak var value: UIView?

    init(_ value: UIView) {
        self.value = value
    }
}

private extension CGRect {
    var isFiniteAndPositive: Bool {
        minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite
            && width > 0 && height > 0
    }
}
