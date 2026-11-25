import UIKit

/// The simplest way to add Digia Engage to a UIKit app: make it the window's root, holding your own
/// root controller.
///
/// ```swift
/// window.rootViewController = DigiaHostViewController(content: navigationController)
/// ```
///
/// It shows `content` full screen and puts a `DigiaHostView` over it, so campaigns draw above every
/// screen you push, every tab and every split column. Your screens keep their status bar style, home
/// indicator and orientation choices: it passes those through to `content`.
///
/// `window.rootViewController` is this controller, not yours; use `content` to reach yours. An app that
/// cannot change its root can add a `DigiaHostView` to each screen instead.
@MainActor
public final class DigiaHostViewController: UIViewController {
    /// The app's own root controller, shown full screen under the host.
    public let content: UIViewController

    public init(content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable, message: "Use init(content:)")
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content.view)
        content.didMove(toParent: self)

        let host = DigiaHostView(frame: view.bounds)
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host)
    }

    // UIKit asks only the root for these, so a container that does not pass them on would make it ignore
    // the app's own choices.
    public override var childForStatusBarStyle: UIViewController? { content }
    public override var childForStatusBarHidden: UIViewController? { content }
    public override var childForHomeIndicatorAutoHidden: UIViewController? { content }
    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        content.supportedInterfaceOrientations
    }
    public override var shouldAutorotate: Bool { content.shouldAutorotate }
}
