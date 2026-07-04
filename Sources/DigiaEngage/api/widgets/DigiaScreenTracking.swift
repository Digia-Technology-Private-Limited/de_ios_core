import UIKit

// MARK: - Manual screen tracking

extension UIViewController {
    /// Reports the current screen name to the Digia SDK.
    ///
    /// Call this in `viewDidAppear` as the UIKit equivalent of Flutter's
    /// `DigiaNavigatorObserver` / Android's `Activity.digiaScreen(name:)` and
    /// `Fragment.digiaScreen(name:)` extensions.
    ///
    /// ```swift
    /// override func viewDidAppear(_ animated: Bool) {
    ///     super.viewDidAppear(animated)
    ///     digiaScreen("HomeScreen")
    /// }
    /// ```
    @MainActor
    public func digiaScreen(_ name: String) {
        Digia.setCurrentScreen(name: name)
    }
}

// MARK: - Automatic screen tracking

/// A `UINavigationControllerDelegate` that automatically tracks screen transitions and
/// forwards them to the registered CEP plugin via `Digia.setCurrentScreen`.
///
/// Opt-in convenience layer mirroring Flutter's `DigiaNavigatorObserver`. Assign it as your
/// navigation controller's delegate for zero-effort screen tracking:
///
/// ```swift
/// let screenObserver = DigiaNavigationScreenObserver()
/// navigationController.delegate = screenObserver
/// ```
///
/// The screen name reported is the view controller's `restorationIdentifier` or `title` if
/// set, falling back to its runtime type name. For edge cases where that name isn't the right
/// one to report, call `digiaScreen(_:)` directly instead.
@MainActor
public final class DigiaNavigationScreenObserver: NSObject, UINavigationControllerDelegate {
    public override init() {}

    public func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        let name = Self.screenName(for: viewController)
        Digia.setCurrentScreen(name: name)
    }

    static func screenName(for viewController: UIViewController) -> String {
        if let restorationIdentifier = viewController.restorationIdentifier,
            !restorationIdentifier.isEmpty
        {
            return restorationIdentifier
        }
        if let title = viewController.title, !title.isEmpty {
            return title
        }
        return String(describing: type(of: viewController))
    }
}
