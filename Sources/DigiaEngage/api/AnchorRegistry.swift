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
    private var activeAvailable: ((String) -> Void)?
    private var activeUnavailable: ((String, AnchorUnavailableReason) -> Void)?
    private var activeAnchorWasAvailable = false
    private let activeViewSampler = ActiveAnchorSampler()
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
        activeAnchorWasAvailable = false
        startReadinessTimeout(for: key)
        startSampling(view: view, key: key)
    }

    public func register(key: String, rect: CGRect, cornerRadius: CGFloat = 0) {
        rectRegistry[key] = rect
        guard viewRegistry[key]?.value == nil else { return }
        viewRegistry.removeValue(forKey: key)
        trackedRects.removeValue(forKey: key)
        cornerRadii[key] = cornerRadius
        version &+= 1
        SDKInstance.shared.recordAnchorSeen(key)
        guard activeKey == key else { return }
        activeAnchorWasAvailable = false
        activeViewSampler.stop()
        startReadinessTimeout(for: key)
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
            activeViewSampler.stop()
            if activeAnchorWasAvailable {
                failActiveAnchor(key: key, reason: .detached)
            } else {
                startReadinessTimeout(for: key)
            }
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
            return ActiveAnchorSampler.resolve(view: view)
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

    func availableRect(for key: String) -> CGRect? {
        if let rect = trackedRects[key] { return rect }
        guard case let .available(rect) = resolution(for: key) else { return nil }
        return rect
    }

    func track(
        key: String?,
        onAvailable: @escaping (String) -> Void,
        onUnavailable: @escaping (String, AnchorUnavailableReason) -> Void
    ) {
        stopTracking()
        guard let key else { return }
        activeKey = key
        activeAvailable = onAvailable
        activeUnavailable = onUnavailable
        activeAnchorWasAvailable = false
        startReadinessTimeout(for: key)

        if let view = viewRegistry[key]?.value {
            startSampling(view: view, key: key)
        } else if rectRegistry[key] != nil {
            validateStaticRect(key: key)
        }
    }

    func stopTracking() {
        if let activeKey { trackedRects.removeValue(forKey: activeKey) }
        activeViewSampler.stop()
        readinessTask?.cancel()
        readinessTask = nil
        activeKey = nil
        activeAvailable = nil
        activeUnavailable = nil
        activeAnchorWasAvailable = false
    }

    func resetForTesting() {
        stopTracking()
        viewRegistry.removeAll()
        rectRegistry.removeAll()
        trackedRects.removeAll()
        cornerRadii.removeAll()
        version &+= 1
    }

    private func startSampling(view: UIView, key: String) {
        activeViewSampler.start(view: view) { [weak self] resolution in
            guard self?.activeKey == key else { return }
            self?.updateTrackedRect(for: key, resolution: resolution)
        }
    }

    private func updateTrackedRect(for key: String, resolution: AnchorResolution) {
        switch resolution {
        case let .available(rect):
            markActiveAnchorAvailable()
            if trackedRects[key].map({ approximatelyEqual($0, rect) }) != true {
                trackedRects[key] = rect
                version &+= 1
            }
        case let .unavailable(reason):
            if activeAnchorWasAvailable {
                failActiveAnchor(key: key, reason: reason)
            }
        case .missing:
            break
        }
    }

    private func validateStaticRect(key: String) {
        switch resolution(for: key) {
        case .available:
            markActiveAnchorAvailable()
        case let .unavailable(reason):
            if activeAnchorWasAvailable {
                failActiveAnchor(key: key, reason: reason)
            }
        case .missing:
            break
        }
    }

    private func startReadinessTimeout(for key: String) {
        guard readinessTask == nil else { return }
        readinessTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.activeKey == key,
                  !self.activeAnchorWasAvailable
            else { return }
            self.failActiveAnchor(key: key, reason: .notReadyTimeout)
        }
    }

    private func markActiveAnchorAvailable() {
        guard !activeAnchorWasAvailable else { return }
        activeAnchorWasAvailable = true
        readinessTask?.cancel()
        readinessTask = nil
        if let activeKey { activeAvailable?(activeKey) }
    }

    private func failActiveAnchor(key: String, reason: AnchorUnavailableReason) {
        guard activeKey == key else { return }
        let callback = activeUnavailable
        stopTracking()
        callback?(key, reason)
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.05
            && abs(lhs.origin.y - rhs.origin.y) < 0.05
            && abs(lhs.size.width - rhs.size.width) < 0.05
            && abs(lhs.size.height - rhs.size.height) < 0.05
    }
}

@MainActor
private final class ActiveAnchorSampler: NSObject {
    private weak var view: UIView?
    private var displayLink: CADisplayLink?
    private var onSample: ((AnchorResolution) -> Void)?

    func start(view: UIView, onSample: @escaping (AnchorResolution) -> Void) {
        stop()
        self.view = view
        self.onSample = onSample
        sample()
        guard self.view != nil, self.onSample != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        view = nil
        onSample = nil
    }

    @objc private func sample() {
        guard let view else {
            onSample?(.unavailable(.detached))
            return
        }
        onSample?(Self.resolve(view: view))
    }

    static func resolve(view: UIView) -> AnchorResolution {
        guard let window = view.window else { return .unavailable(.detached) }
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
            isVisible: isVisible(view)
        )
    }

    private static func isVisible(_ view: UIView) -> Bool {
        var candidate: UIView? = view
        while let current = candidate {
            let opacity = current.layer.presentation()?.opacity ?? current.layer.opacity
            if current.isHidden || opacity <= 0 { return false }
            candidate = current.superview
        }
        return true
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
