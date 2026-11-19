import SwiftUI
import UIKit

/// UIKit host for Digia Engage: what `DigiaHost` is to SwiftUI, and the same name and behavior as
/// Android's `DigiaHostView`. It draws nudges, surveys, guides and floaters over your content.
///
/// Most apps do not add it themselves: `DigiaHostViewController` as the window's root adds one above
/// every screen. Add it yourself only when your app cannot change its root, as the **last, full-screen
/// subview** of each screen's view, in code or Interface Builder:
///
/// ```swift
/// let host = DigiaHostView(frame: view.bounds)
/// host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
/// view.addSubview(host) // last, so it draws on top
/// ```
///
/// A host in one screen's view draws only while that screen is on screen. Do not add it directly to
/// the view of a `UINavigationController`, `UITabBarController`, `UISplitViewController` or
/// `UIPageViewController` (those treat a child controller as one of their own screens), nor straight
/// to a `UIWindow` (it needs a view controller whose view contains it). There it draws nothing and
/// logs a warning.
///
/// Touches go to your views unless a campaign is showing. Use exactly one: a second host would
/// present the same campaign twice. Without one, a campaign is accepted but never drawn, and is
/// dropped as `timeout` after 15 seconds.
@MainActor
public final class DigiaHostView: UIView {
    private let log = DigiaLogger()
    private var hostingController: UIHostingController<DigiaHost<EmptyView>>?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            unmount()
        } else if hostingController == nil {
            mount()
        }
    }

    /// Lets touches through to the app unless the SDK is drawing something at that point.
    ///
    /// SwiftUI answers a hit test with the hosting view itself for empty space, so "the hosting view
    /// hit" means "nothing here" and falls through. Three things are drawn without a view of their
    /// own to hit, so each is claimed explicitly: a full-screen overlay (its scrim is a bare gesture),
    /// and the debug bubble and the floater window (small boxes that cannot be told apart from empty
    /// space). Their frames are in SwiftUI's global space, which is the window's.
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hostedView = hostingController?.view else { return nil }
        let hit = hostedView.hitTest(convert(point, to: hostedView), with: event)
        let windowPoint = convert(point, to: nil)
        let claimed =
            Digia.hasActiveOverlay
            || Digia.debugBadgeFrame?.contains(windowPoint) == true
            || Digia.floaterActiveRect?.contains(windowPoint) == true
        if claimed { return hit ?? hostedView }
        guard let hit, hit !== hostedView else { return nil }
        return hit
    }

    private func mount() {
        guard let parent = owningViewController else {
            log.w(
                "DigiaHostView is not inside a plain view controller's view (not directly in a navigation, tab "
                    + "bar or split view controller, whose child is its own screen, and not added straight to a "
                    + "window), so campaigns cannot be drawn")
            return
        }
        let controller = UIHostingController(rootView: DigiaHost { EmptyView() })
        controller.view.backgroundColor = .clear
        controller.view.translatesAutoresizingMaskIntoConstraints = false

        parent.addChild(controller)
        addSubview(controller.view)
        controller.didMove(toParent: parent)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hostingController = controller
    }

    private func unmount() {
        guard let controller = hostingController else { return }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        hostingController = nil
    }
}

extension UIView {
    /// The view controller to hang an embedded SwiftUI controller on: the nearest one up the
    /// responder chain, climbing past any that manage their own children. Adding a child to one of
    /// those changes the app: a navigation controller pushes it as a screen, a tab bar controller
    /// adds a tab.
    ///
    /// A view added straight to a window has none, even though the window has a root controller:
    /// UIKit throws when a child controller's view is added outside its parent's view, and the
    /// window's root controller's view does not contain a window's own subviews.
    var owningViewController: UIViewController? {
        var responder: UIResponder? = self
        var controller: UIViewController?
        while let current = responder, controller == nil {
            controller = current as? UIViewController
            responder = current.next
        }
        while let current = controller, current.managesItsChildren {
            controller = current.parent
        }
        return controller
    }
}

private extension UIViewController {
    var managesItsChildren: Bool {
        self is UINavigationController || self is UITabBarController
            || self is UISplitViewController || self is UIPageViewController
    }
}
