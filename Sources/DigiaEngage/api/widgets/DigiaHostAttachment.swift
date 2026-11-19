import UIKit

/// What `Digia.attach(to:)` does: keeps one `DigiaHostView` as the last subview of the window's
/// *current* root view controller, so its SwiftUI layer is that root's child controller.
///
/// The app calls `attach` once. A root swap (`window.rootViewController = …`) removes the host with the
/// old root, so it is put back twice over: right after the swap, by observing the window's root, and
/// again before each campaign is routed (`ensure()`), because UIKit does not promise that observation.
/// A campaign that was on screen in the old root is ended first (`endCampaignsForHostTeardown`): it left
/// the screen with that root, and is not redrawn in the new one.
///
/// A navigation, tab bar, split view or page view controller root is not supported: each of them
/// treats any child controller as one of its own screens (a pushed page, an extra tab). There the host
/// is not added, a warning is logged, and campaigns are not drawn.
@MainActor
enum DigiaHostAttachment {
    private static let log = DigiaLogger()
    private static weak var window: UIWindow?
    private static var host: DigiaHostView?
    private static var rootObservation: NSKeyValueObservation?
    private static weak var warnedRoot: UIViewController?
    /// The root the host was last added to. An identity, not a reference: the old root is usually gone by
    /// the time the swap is noticed, and a weak reference would then read as "never attached".
    private static var attachedRoot: ObjectIdentifier?

    static func attach(to window: UIWindow) {
        if self.window !== window {
            self.window = window
            rootObservation = window.observe(\.rootViewController) { _, _ in
                // On the next turn, once UIKit has put the new root's view in the window.
                DispatchQueue.main.async { MainActor.assumeIsolated { ensure() } }
            }
        }
        ensure()
    }

    /// Puts the host back in the current root, or on top of it, if it is not already there.
    static func ensure() {
        guard let window, let root = window.rootViewController else { return }
        if let attached = attachedRoot, attached != ObjectIdentifier(root) {
            attachedRoot = nil
            SDKInstance.shared.endCampaignsForHostTeardown()
        }
        guard !root.managesItsChildren else {
            host?.removeFromSuperview()
            if warnedRoot !== root {
                warnedRoot = root
                log.w(
                    "Digia.attach(to:) does not support a \(type(of: root)) as the window's root: it would treat "
                        + "Digia's layer as one of its own screens. Campaigns are not drawn. Make a plain view "
                        + "controller the root and put your \(type(of: root)) inside it.")
            }
            return
        }
        let host = self.host ?? DigiaHostView(frame: root.view.bounds)
        self.host = host
        if host.superview !== root.view {
            // Out of the window first, so the host re-mounts with the new root as its parent.
            host.removeFromSuperview()
            host.frame = root.view.bounds
            host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            root.view.addSubview(host)
        } else if root.view.subviews.last !== host {
            root.view.bringSubviewToFront(host)
        }
        attachedRoot = ObjectIdentifier(root)
    }
}
