import SwiftUI

private enum Material3LightOverlay {
    static let surfaceContainer = Color(red: 243 / 255, green: 237 / 255, blue: 247 / 255)
}

enum NavigationUtil {
    static func normalizedRoute(_ route: String) -> String {
        let trimmed = route.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("/") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    @MainActor
    static func enableInteractivePopGestureIfNeeded(for navigationController: UINavigationController?) {
        guard let navigationController, navigationController.viewControllers.count > 1 else { return }
        guard let popGesture = navigationController.interactivePopGestureRecognizer else { return }
        popGesture.isEnabled = true
        popGesture.delegate = nil
    }

    @MainActor
    static func presentBottomSheetContent<Content: View>(
        presentation: DigiaBottomSheetPresentation,
        overlayController: DigiaOverlayController,
        transition: BottomSheetTransitionModel,
        dismissesPresentedViewController: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DigiaModalBottomSheetRootView(
            presentation: presentation,
            overlayController: overlayController,
            transition: transition,
            dismissesPresentedViewController: dismissesPresentedViewController,
            content: content
        )
    }

    @MainActor
    static func presentDialogContent<Content: View>(
        presentation: DigiaDialogPresentation,
        overlayController: DigiaOverlayController,
        dismissesPresentedViewController: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DigiaDialogRouteRootView(
            presentation: presentation,
            overlayController: overlayController,
            dismissesPresentedViewController: dismissesPresentedViewController,
            content: content
        )
    }
}

@MainActor
private struct DigiaDialogRouteRootView<Content: View>: View {
    let presentation: DigiaDialogPresentation
    let overlayController: DigiaOverlayController
    let dismissesPresentedViewController: Bool
    @ViewBuilder var content: () -> Content

    private let horizontalInset: CGFloat = 40
    private let verticalInset: CGFloat = 24
    private let maxDialogWidthCap: CGFloat = 560

    @State private var contentWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let safe = geo.safeAreaInsets
            let availableW = geo.size.width - safe.leading - safe.trailing - horizontalInset * 2
            let maxContentW = min(maxDialogWidthCap, max(0, availableW))

            ZStack {
                presentation.barrierColor
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if presentation.barrierDismissible {
                            dismiss()
                        }
                    }

                VStack {
                    Spacer(minLength: 0)

                    content()
                        .fixedSize(horizontal: true, vertical: true)
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear {
                                        contentWidth = proxy.size.width
                                    }
                            }
                        )
                        .frame(
                            width: min(contentWidth, maxContentW) // ✅ hard clamp, no expansion
                        )
                        .background {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(Material3LightOverlay.surfaceContainer)
                        }
                        .clipShape(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                        )
                        .shadow(
                            color: Color.black.opacity(0.12),
                            radius: 10,
                            x: 0,
                            y: 4
                        )

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity) // center
                .padding(.horizontal, horizontalInset)
                .padding(.vertical, verticalInset)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    private func dismiss() {
        if dismissesPresentedViewController {
            ViewControllerUtil.dismissPresented(animated: false) {
                overlayController.dismissDialog()
            }
        } else {
            overlayController.dismissDialog()
        }
    }
}



@MainActor
private struct DigiaModalBottomSheetRootView<Content: View>: View {
    let presentation: DigiaBottomSheetPresentation
    let overlayController: DigiaOverlayController
    @ObservedObject var transition: BottomSheetTransitionModel
    let dismissesPresentedViewController: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            let screenH = UIScreen.main.bounds.height
            let layoutH = max(geo.size.height, screenH)
            let maxAllowedHeight = layoutH * presentation.maxHeight
            let clipShape = WidgetUtil.shape(for: presentation.cornerRadius)
            let sheetMaxWidth = min(640, max(geo.size.width, UIScreen.main.bounds.width))
            let safeAreaBottom: CGFloat = {
                guard presentation.useSafeArea else { return 0 }
                let windowInset = ViewControllerUtil.topViewController()?.view.window?.safeAreaInsets.bottom ?? 0
                return max(windowInset, geo.safeAreaInsets.bottom)
            }()

            ZStack(alignment: .bottom) {
                bottomSheetBarrierLayer()
                    .opacity(transition.barrierOpacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .allowsHitTesting(transition.barrierOpacity > 0.5)
                    .onTapGesture {
                        transition.animateDismiss {
                            if dismissesPresentedViewController {
                                ViewControllerUtil.dismissPresented(animated: false) {
                                    overlayController.dismissBottomSheet()
                                    SDKInstance.shared.didDismissBottomSheet()
                                }
                            } else {
                                overlayController.dismissBottomSheet()
                                SDKInstance.shared.didDismissBottomSheet()
                            }
                        }
                    }

                VStack(spacing: 0) {
                    content()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, safeAreaBottom)
                .frame(maxWidth: sheetMaxWidth)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: maxAllowedHeight, alignment: .top)
                .background {
                    digiaBottomSheetChromeBackground(clipShape: clipShape)
                }
                .clipShape(clipShape)
                .overlay {
                    digiaBottomSheetChromeStroke(clipShape: clipShape)
                }
                .offset(y: transition.sheetOffset)
            }
            .frame(width: max(geo.size.width, UIScreen.main.bounds.width), height: layoutH)
            .onAppear {
                transition.updateContainerHeight(layoutH)
                transition.runEnterAnimationIfNeeded(containerHeight: layoutH)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func bottomSheetBarrierLayer() -> some View {
        presentation.barrierColor
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }

    @ViewBuilder
    private func digiaBottomSheetChromeBackground(clipShape: AnyShape) -> some View {
        clipShape.fill(presentation.sheetBackgroundColor ?? Material3LightOverlay.surfaceContainer)
    }

    @ViewBuilder
    private func digiaBottomSheetChromeStroke(clipShape: AnyShape) -> some View {
        if presentation.shouldDrawBorder, let borderColor = presentation.borderColor {
            clipShape.stroke(borderColor, lineWidth: presentation.effectiveBorderWidth)
        }
    }
}
