import Foundation
import SnapshotTesting
import SwiftUI
import UIKit
@testable import DigiaEngage

/// Reusable host view controller factory and mounting utilities for component and device-level snapshot testing.
@MainActor
public enum ComponentTestHost {

    /// Host app background presentation styles for device-level snapshot testing.
    public enum BackgroundStyle {
        /// Plain solid color background (defaults to white).
        case solid(UIColor = .white)

        /// Realistic host application UI with white navigation bar and sample cards on a grouped light background.
        case mockApp(title: String = "Host App", showBottomBar: Bool = false)
    }

    /// Creates an isolated component host controller at exact dimensions with a background color.
    ///
    /// Ideal for single-widget pixel tests and layout AST dumps.
    /// - Parameters:
    ///   - rootView: The SwiftUI view to host.
    ///   - size: Authored or target layout dimensions.
    ///   - backgroundColor: Host view background (defaults to `.white`).
    /// - Returns: A configured `UIHostingController` with laid-out bounds.
    public static func makeComponentHost<Content: View>(
        rootView: Content,
        size: CGSize,
        backgroundColor: UIColor = .white
    ) -> UIHostingController<Content> {
        let controller = UIHostingController(rootView: rootView)
        controller.view.bounds = CGRect(origin: .zero, size: size)
        controller.view.backgroundColor = backgroundColor
        controller.view.layoutIfNeeded()
        return controller
    }

    /// Creates a full-screen device host controller with optional background style and backdrop scrim.
    /// - Parameters:
    ///   - device: Target device configuration preset (defaults to `.iPhone17ProMax`).
    ///   - style: Background presentation style (defaults to solid white).
    ///   - scrimColor: Optional dimming overlay color (defaults to 40% black scrim).
    ///   - showHomeIndicator: Whether to render the system home indicator overlay.
    /// - Returns: A configured `UIViewController` ready to host overlays.
    public static func makeDeviceHost(
        device: ViewImageConfig = .iPhone17ProMax,
        style: BackgroundStyle = .solid(.white),
        scrimColor: UIColor? = UIColor.black.withAlphaComponent(0.4),
        showHomeIndicator: Bool = false
    ) -> UIViewController {
        guard let size = device.size else {
            fatalError("Device configuration must have a concrete size")
        }
        let hostWidth = size.width
        let hostHeight = size.height
        let hostVC = UIViewController()
        hostVC.view.frame = CGRect(x: 0, y: 0, width: hostWidth, height: hostHeight)

        switch style {
        case .solid(let color):
            hostVC.view.backgroundColor = color

        case .mockApp(let title, let showBottomBar):
            hostVC.view.backgroundColor = UIColor(white: 0.96, alpha: 1.0)
            let mockAppView = buildMockAppView(
                title: title,
                width: hostWidth,
                height: hostHeight,
                safeAreaTop: device.safeArea.top,
                safeAreaBottom: device.safeArea.bottom,
                showBottomBar: showBottomBar
            )
            hostVC.view.addSubview(mockAppView)
        }

        // Optional backdrop scrim (dimming)
        if let scrim = scrimColor {
            let backdrop = UIView(frame: hostVC.view.bounds)
            backdrop.backgroundColor = scrim
            hostVC.view.addSubview(backdrop)
        }

        // Optional system Home Indicator overlay
        if showHomeIndicator && device.safeArea.bottom > 0 {
            let indicator = makeHomeIndicator(hostWidth: hostWidth, hostHeight: hostHeight)
            hostVC.view.addSubview(indicator)
        }

        return hostVC
    }

    /// Mounts a bottom sheet view controller flush at the bottom of the device host.
    /// - Parameters:
    ///   - rootView: The SwiftUI bottom sheet view.
    ///   - sheetHeight: Authored height of the sheet.
    ///   - hostVC: The device host controller to embed into.
    /// - Returns: The child `UIHostingController` displaying the bottom sheet.
    @discardableResult
    public static func mountBottomSheet<Content: View>(
        rootView: Content,
        sheetHeight: CGFloat,
        in hostVC: UIViewController
    ) -> UIHostingController<Content> {
        let sheetVC = UIHostingController(rootView: rootView)
        let hostBounds = hostVC.view.bounds
        sheetVC.view.frame = CGRect(
            x: 0,
            y: hostBounds.height - sheetHeight,
            width: hostBounds.width,
            height: sheetHeight
        )
        sheetVC.view.backgroundColor = .clear
        hostVC.addChild(sheetVC)
        hostVC.view.addSubview(sheetVC.view)
        sheetVC.didMove(toParent: hostVC)
        return sheetVC
    }

    /// Mounts a dialog view controller centered within the device host.
    /// - Parameters:
    ///   - rootView: The SwiftUI dialog view.
    ///   - dialogSize: Dimensions of the dialog.
    ///   - hostVC: The device host controller to embed into.
    /// - Returns: The child `UIHostingController` displaying the dialog.
    @discardableResult
    public static func mountDialog<Content: View>(
        rootView: Content,
        dialogSize: CGSize,
        in hostVC: UIViewController
    ) -> UIHostingController<Content> {
        let dialogVC = UIHostingController(rootView: rootView)
        let hostBounds = hostVC.view.bounds
        let x = (hostBounds.width - dialogSize.width) / 2
        let y = (hostBounds.height - dialogSize.height) / 2
        dialogVC.view.frame = CGRect(x: x, y: y, width: dialogSize.width, height: dialogSize.height)
        dialogVC.view.backgroundColor = .clear
        hostVC.addChild(dialogVC)
        hostVC.view.addSubview(dialogVC.view)
        dialogVC.didMove(toParent: hostVC)
        return dialogVC
    }

    /// Creates a full-screen device host rendering the REAL production Nudge Bottom Sheet (`NudgeSheetView` wrapping `DigiaBottomSheet`).
    ///
    /// This includes the full production hierarchy:
    /// - Top drag handle capsule (when `showHandle` is enabled)
    /// - Scrim dimming backdrop
    /// - Bottom safe-area clearance (`none`, `insetContent`, `insetSurface`)
    /// - Rounded corner clipping
    /// - Canvas contents inside the sheet
    /// Creates a full-screen device window rendering the REAL production `NudgeOverlayView`
    /// with zero changes to production code.
    @MainActor
    public static func makeRealOverlayWindow(
        nudgeConfig: NudgeConfig,
        device: ViewImageConfig = .iPhone17ProMax,
        style: BackgroundStyle = .solid(.white)
    ) -> UIWindow {
        guard let size = device.size else {
            fatalError("Device configuration must have a concrete size")
        }

        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
        }
        window.frame = CGRect(origin: .zero, size: size)

        let rootVC = makeDeviceHost(
            device: device,
            style: style,
            scrimColor: nil,
            showHomeIndicator: false
        )

        let overlayVC = UIHostingController(rootView: NudgeOverlayView())
        overlayVC.view.frame = CGRect(origin: .zero, size: size)
        overlayVC.view.backgroundColor = .clear
        rootVC.addChild(overlayVC)
        rootVC.view.addSubview(overlayVC.view)
        overlayVC.didMove(toParent: rootVC)

        window.rootViewController = rootVC
        window.makeKeyAndVisible()

        let presentation = DigiaNudgePresentation(
            config: nudgeConfig,
            payload: CEPTriggerPayload(
                cepCampaignId: "test_nudge",
                campaignKey: "test_nudge_key",
                cepMetadata: [:]
            ),
            variables: nil
        )

        SDKInstance.shared.controller.showNudge(presentation)

        drainRunLoop(for: 1.0)
        window.layoutIfNeeded()

        return window
    }

    /// Dismisses the nudge and tears the window down.
    @MainActor
    public static func cleanupOverlayWindow(_ viewOrWindow: AnyObject?) {
        let targetWindow: UIWindow? = (viewOrWindow as? UIWindow) ?? (viewOrWindow as? UIView)?.window
        SDKInstance.shared.controller.forceNudgeDismiss()
        drainRunLoop(for: 0.1)
        targetWindow?.rootViewController?.dismiss(animated: false)
        targetWindow?.rootViewController = nil
        targetWindow?.isHidden = true
        targetWindow?.resignKey()
    }

    /// Renders a live overlay window (including any presented cover) to an image. Pass this to
    /// `assertSnapshot` instead of the window itself: SnapshotTesting re-parents and re-lays-out the
    /// view it is given, which leaves the window's hosting view in a state where its next SwiftUI
    /// render crashes in `_UIHostingView.rootTransform()` (EXC_BAD_ACCESS).
    @MainActor
    public static func renderImage(of view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
    }

    @MainActor
    private static func drainRunLoop(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// Renders the complete production overlay and presents its bottom sheet through the SDK controller.
    @MainActor
    public static func makeRealBottomSheetHost(
        nudgeConfig: NudgeConfig,
        device: ViewImageConfig = .iPhone17ProMax,
        style: BackgroundStyle = .solid(.white)
    ) -> UIView {
        makeRealOverlayWindow(nudgeConfig: nudgeConfig, device: device, style: style)
    }

    @MainActor
    public static func makeRealDialogHost(
        nudgeConfig: NudgeConfig,
        device: ViewImageConfig = .iPhone17ProMax,
        style: BackgroundStyle = .solid(.white)
    ) -> UIView {
        makeRealOverlayWindow(nudgeConfig: nudgeConfig, device: device, style: style)
    }

    // MARK: - Private Mock UI Builders

    private static func makeHomeIndicator(hostWidth: CGFloat, hostHeight: CGFloat) -> UIView {
        let indicatorWidth: CGFloat = 134
        let indicatorHeight: CGFloat = 5
        let indicatorBottomMargin: CGFloat = 8
        let indicatorView = UIView(frame: CGRect(
            x: (hostWidth - indicatorWidth) / 2,
            y: hostHeight - indicatorHeight - indicatorBottomMargin,
            width: indicatorWidth,
            height: indicatorHeight
        ))
        indicatorView.backgroundColor = UIColor.label.withAlphaComponent(0.85)
        indicatorView.layer.cornerRadius = indicatorHeight / 2
        indicatorView.isUserInteractionEnabled = false
        return indicatorView
    }

    private static func buildMockAppView(
        title: String,
        width: CGFloat,
        height: CGFloat,
        safeAreaTop: CGFloat,
        safeAreaBottom: CGFloat,
        showBottomBar: Bool
    ) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        container.backgroundColor = UIColor(white: 0.96, alpha: 1.0)

        // 1. Navigation Bar (White header)
        let navBarHeight: CGFloat = 44
        let totalHeaderHeight = safeAreaTop + navBarHeight
        let navBar = UIView(frame: CGRect(x: 0, y: 0, width: width, height: totalHeaderHeight))
        navBar.backgroundColor = .white

        let titleLabel = UILabel(frame: CGRect(x: 16, y: safeAreaTop + 8, width: width - 32, height: 28))
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .black
        navBar.addSubview(titleLabel)

        let navDivider = UIView(frame: CGRect(x: 0, y: totalHeaderHeight - 1, width: width, height: 1))
        navDivider.backgroundColor = UIColor(white: 0.88, alpha: 1.0)
        navBar.addSubview(navDivider)
        container.addSubview(navBar)

        // 2. Mock Content Cards (Feed rows with white background)
        var cardY = totalHeaderHeight + 16
        for i in 0..<3 {
            let cardHeight: CGFloat = 80
            let card = UIView(frame: CGRect(x: 16, y: cardY, width: width - 32, height: cardHeight))
            card.backgroundColor = .white
            card.layer.cornerRadius = 12
            card.layer.borderWidth = 1
            card.layer.borderColor = UIColor(white: 0.90, alpha: 1.0).cgColor

            let placeholderBar = UIView(frame: CGRect(x: 16, y: 20, width: width - 96, height: 14))
            placeholderBar.backgroundColor = UIColor(white: 0.92, alpha: 1.0)
            placeholderBar.layer.cornerRadius = 4
            card.addSubview(placeholderBar)

            let subtitleBar = UIView(frame: CGRect(x: 16, y: 44, width: (width - 96) * 0.6, height: 10))
            subtitleBar.backgroundColor = UIColor(white: 0.95, alpha: 1.0)
            subtitleBar.layer.cornerRadius = 3
            card.addSubview(subtitleBar)

            container.addSubview(card)
            cardY += cardHeight + 12
        }

        // 3. Optional Bottom Tab Bar
        if showBottomBar {
            let barHeight: CGFloat = 49 + safeAreaBottom
            let bottomBar = UIView(frame: CGRect(x: 0, y: height - barHeight, width: width, height: barHeight))
            bottomBar.backgroundColor = .white

            let barDivider = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 1))
            barDivider.backgroundColor = UIColor(white: 0.88, alpha: 1.0)
            bottomBar.addSubview(barDivider)

            let tabTitles = ["Home", "Explore", "Profile"]
            let tabWidth = width / CGFloat(tabTitles.count)
            for (idx, tabTitle) in tabTitles.enumerated() {
                let tabLabel = UILabel(frame: CGRect(x: CGFloat(idx) * tabWidth, y: 12, width: tabWidth, height: 18))
                tabLabel.text = tabTitle
                tabLabel.textAlignment = .center
                tabLabel.font = .systemFont(ofSize: 11, weight: idx == 0 ? .semibold : .regular)
                tabLabel.textColor = idx == 0 ? .systemBlue : .gray
                bottomBar.addSubview(tabLabel)
            }
            container.addSubview(bottomBar)
        }

        return container
    }
}
