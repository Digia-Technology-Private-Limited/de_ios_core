import ObjectiveC
import SnapshotTesting
import UIKit

/// The reference phone (`ViewImageConfig.engageGolden`: 390x844, safe area 47/34) for SDK code that
/// asks the system instead of the view it is in, so a UI test lays out the same on any simulator
/// without a test seam in the SDK.
///
/// The SDK reads `UIScreen.main.bounds` (the survey's scale and height, every window fallback) and a
/// window's `safeAreaInsets` (survey, inline story, guide, nudge), sometimes the app's own window rather
/// than the test's. Neither can be set from outside, so `pin` redirects both getters for the rest of the
/// test process: every `UIScreen` reports the reference screen and every `UIWindow` its insets. The
/// sample app's tests pin once, as the bundle loads (`SampleTestBundle`); a SwiftPM test bundle has no
/// such hook, so the package's tests pin in `ComponentTestHost`, where every test window
/// (`makeWindow`) and window-less host comes from. Calling it again does nothing.
///
/// UIKit hands a window's reported insets down to its root view controller only in part, so a test that
/// needs the view's own safe area to be the reference's corrects it with `pinSafeArea(of:)`.
enum GoldenScreen {
    private static let screenBounds = CGRect(origin: .zero, size: ViewImageConfig.engageGolden.size!)
    private static let safeArea = ViewImageConfig.engageGolden.safeArea

    /// Redirects `-[UIScreen bounds]` and `-[UIWindow safeAreaInsets]` to the reference phone's, for the
    /// rest of the process. Test bundle only.
    @MainActor static func pin() {
        _ = redirect
    }

    /// Sets `controller`'s additional insets so its view's safe area is exactly the reference's, whatever
    /// part of the window's the system passed down. Call it once the window is laid out.
    @MainActor static func pinSafeArea(of controller: UIViewController) {
        controller.additionalSafeAreaInsets = .zero
        controller.view.layoutIfNeeded()
        let given = controller.view.safeAreaInsets
        controller.additionalSafeAreaInsets = UIEdgeInsets(
            top: safeArea.top - given.top, left: safeArea.left - given.left,
            bottom: safeArea.bottom - given.bottom, right: safeArea.right - given.right)
        controller.view.layoutIfNeeded()
    }

    /// Shades the safe area of a full-screen capture, black at 40% (`0x66`) as on Flutter and Android, so a golden shows
    /// what the SDK draws under the notch and the home indicator. Drawn on the picture, so it lies over every window and
    /// never takes a touch.
    static func shadeSafeArea(of image: UIImage) -> UIImage {
        UIGraphicsImageRenderer(size: image.size, format: image.imageRendererFormat).image { context in
            image.draw(at: .zero)
            UIColor(white: 0, alpha: 0x66 / 255.0).setFill()
            let width = image.size.width
            context.fill(CGRect(x: 0, y: 0, width: width, height: safeArea.top), blendMode: .normal)
            context.fill(
                CGRect(x: 0, y: image.size.height - safeArea.bottom, width: width, height: safeArea.bottom),
                blendMode: .normal)
        }
    }

    private static let redirect: Void = {
        let bounds = #selector(getter: UIScreen.bounds)
        let screenGetter = class_getInstanceMethod(UIScreen.self, bounds)!
        let screen: @convention(block) (UIScreen) -> CGRect = { _ in screenBounds }
        method_setImplementation(screenGetter, imp_implementationWithBlock(screen))

        // Added to `UIWindow` itself when it inherits the getter, so other views keep `UIView`'s.
        let insets = #selector(getter: UIView.safeAreaInsets)
        let windowGetter = class_getInstanceMethod(UIWindow.self, insets)!
        let window: @convention(block) (UIWindow) -> UIEdgeInsets = { _ in safeArea }
        let reference = imp_implementationWithBlock(window)
        if !class_addMethod(UIWindow.self, insets, reference, method_getTypeEncoding(windowGetter)) {
            method_setImplementation(windowGetter, reference)
        }
    }()
}
