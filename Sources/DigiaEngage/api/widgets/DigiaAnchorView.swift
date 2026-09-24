import UIKit

/// UIKit anchor for guide steps. Add the anchored content as subviews and set
/// `anchorKey` (in code or Interface Builder). While it is in a window, the
/// first subview (the anchored content) is registered, or the view itself when
/// it has none, as Android's `DigiaAnchorView` does. The guide tracks that
/// view and can scroll it into view.
public final class DigiaAnchorView: UIView {
    @IBInspectable public var anchorKey: String = "" {
        didSet {
            guard oldValue != anchorKey else { return }
            unregisterTarget(key: oldValue)
            registerIfNeeded()
        }
    }

    /// The view currently registered under `anchorKey`.
    private weak var registeredTarget: UIView?

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            unregisterTarget(key: anchorKey)
        } else {
            registerIfNeeded()
        }
    }

    public override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        registerIfNeeded()
    }

    public override func willRemoveSubview(_ subview: UIView) {
        super.willRemoveSubview(subview)
        guard subview === registeredTarget else { return }
        registerIfNeeded(target: subviews.first { $0 !== subview } ?? self)
    }

    private func registerIfNeeded(target: UIView? = nil) {
        guard window != nil, !anchorKey.isEmpty else { return }
        let target = target ?? subviews.first ?? self
        guard target !== registeredTarget else { return }
        let previous = registeredTarget
        // The new target first, so swapping targets is never seen as the
        // anchor leaving the screen.
        AnchorRegistry.shared.register(key: anchorKey, view: target)
        registeredTarget = target
        if let previous {
            AnchorRegistry.shared.unregister(key: anchorKey, view: previous)
        }
    }

    private func unregisterTarget(key: String) {
        guard let target = registeredTarget else { return }
        registeredTarget = nil
        if !key.isEmpty {
            AnchorRegistry.shared.unregister(key: key, view: target)
        }
    }
}
