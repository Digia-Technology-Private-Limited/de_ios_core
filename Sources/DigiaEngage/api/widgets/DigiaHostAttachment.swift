import SwiftUI
import UIKit

/// What `Digia.attach(to:)` does: keeps one `DigiaHostView` as the last subview of the window's
/// *current* root view controller, so its SwiftUI layer is that root's child controller.
///
/// The app calls `attach` once. A root swap (`window.rootViewController = …`) removes the host with the
/// old root; it is put back before the next campaign is routed (`ensure()`). A campaign that was on
/// screen in the old root is ended at that point (`endCampaignsForHostTeardown`): it left the screen with
/// that root, and is not redrawn in the new one.
///
/// A navigation, tab bar, split view or page view controller root is not supported: each of them
/// treats any child controller as one of its own screens (a pushed page, an extra tab). There the host
/// is not added, a warning is logged, and campaigns are not drawn.
@MainActor
enum DigiaHostAttachment {
    private static let log = DigiaLogger()
    private(set) static weak var window: UIWindow?
    private static var host: DigiaHostView?
    private static weak var warnedRoot: UIViewController?
    /// Whether the host was added to a root and has not been found missing since.
    private static var attached = false

    /// Whether the app called `Digia.attach(to:)`, for a window that still exists.
    static var isInUse: Bool { window != nil }

    /// Whether the attached host is in the window's current root, on screen.
    static var hasHost: Bool {
        guard attached, let host, let root = window?.rootViewController else { return false }
        return host.superview === root.view && host.window != nil
    }

    /// The first controller the app itself presented in `window`, if any. Digia's own debug
    /// screen is skipped; its nudge covers, surveys and stories are told apart by their state instead.
    static func appPresentation(in window: UIWindow?) -> UIViewController? {
        var presented = window?.rootViewController?.presentedViewController
        while let current = presented {
            if !(current is UIHostingController<DigiaDebugSettingsView>) {
                return current
            }
            presented = current.presentedViewController
        }
        return nil
    }

    static func attach(to window: UIWindow) {
        self.window = window
        HostRegistry.shared.enforce()
        ensure()
    }

    /// Puts the host back in the current root, or on top of it, if it is not already there.
    static func ensure() {
        guard let window, let root = window.rootViewController else { return }
        if attached, host?.superview !== root.view {
            // The host is no longer in the window's root: the app replaced the root.
            attached = false
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
        attached = true
    }
}
