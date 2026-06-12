import UIKit

@MainActor
enum ViewControllerUtil {
    /// The active foreground window scene, used to host dedicated overlay
    /// windows (e.g. the full-screen inline story).
    static func findWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.keyWindow != nil })
            ?? scenes.first
    }

    /// The window to present from. Prefers the scene's key window, but falls back
    /// to any visible window — React Native hosts often have no `isKeyWindow`
    /// window flagged at the moment a tap fires, which would otherwise leave us
    /// with a `nil` key window and a silently dropped presentation.
    static func keyWindow() -> UIWindow? {
        guard let scene = findWindowScene() else { return nil }
        return scene.keyWindow
            ?? scene.windows.first(where: { $0.isKeyWindow })
            ?? scene.windows.first(where: { !$0.isHidden && $0.rootViewController != nil })
            ?? scene.windows.first
    }

    /// The top-most view controller, walking the presentation chain from the
    /// given base (or the key window's root) so modals stack correctly.
    static func topViewController(base: UIViewController? = nil) -> UIViewController? {
        guard var top = base ?? keyWindow()?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    /// Presents a view controller from the top-most controller, with iPad popover
    /// anchoring so sheets (e.g. the share sheet) don't crash on regular widths.
    static func present(_ viewController: UIViewController, animated: Bool = true) {
        guard let top = topViewController() else { return }
        if let popover = viewController.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY,
                                        width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(viewController, animated: animated)
    }
}
