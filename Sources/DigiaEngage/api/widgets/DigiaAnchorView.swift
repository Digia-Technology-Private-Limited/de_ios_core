import UIKit

/// UIKit anchor for guide steps. Add the anchored content as subviews and set
/// `anchorKey` (in code or Interface Builder). The view registers itself while
/// it is in a window, so the guide tracks it and can scroll it into view.
public final class DigiaAnchorView: UIView {
    @IBInspectable public var anchorKey: String = "" {
        didSet {
            guard oldValue != anchorKey else { return }
            if !oldValue.isEmpty {
                AnchorRegistry.shared.unregister(key: oldValue, view: self)
            }
            registerIfNeeded()
        }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            if !anchorKey.isEmpty {
                AnchorRegistry.shared.unregister(key: anchorKey, view: self)
            }
        } else {
            registerIfNeeded()
        }
    }

    private func registerIfNeeded() {
        guard window != nil, !anchorKey.isEmpty else { return }
        AnchorRegistry.shared.register(key: anchorKey, view: self)
    }
}
