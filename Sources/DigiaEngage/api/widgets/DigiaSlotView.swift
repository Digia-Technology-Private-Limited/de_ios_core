import SwiftUI
import UIKit

/// UIKit counterpart of `DigiaSlot`, and the same name as Android's `DigiaSlotView`. It shows the
/// inline campaign configured for `placementKey`, and takes no space while there is none.
///
/// Set `placementKey` in code or Interface Builder. Give the view a position and a width and let its
/// height come from the content, as with a label:
///
/// ```swift
/// let slot = DigiaSlotView()
/// slot.placementKey = "home_banner"
/// stack.addArrangedSubview(slot)
/// ```
@MainActor
public final class DigiaSlotView: UIView {
    @IBInspectable public var placementKey: String = "" {
        didSet {
            guard oldValue != placementKey else { return }
            remount()
        }
    }

    private let log = DigiaLogger()
    private var hostingController: SlotHostingController?
    private var measuredHeight: CGFloat = 0
    private var measurementScheduled = false

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            unmount()
        } else if hostingController == nil {
            remount()
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        scheduleMeasurement()
    }

    private func remount() {
        unmount()
        guard window != nil, !placementKey.isEmpty else { return }
        guard let parent = owningViewController else {
            log.w("DigiaSlotView '\(placementKey)' is not in a view controller's hierarchy, so it cannot show content")
            return
        }
        let controller = SlotHostingController(rootView: DigiaSlot(placementKey))
        controller.view.backgroundColor = .clear
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        // The slot sits in the middle of the app's layout, so the safe area is not its concern.
        if #available(iOS 16.4, *) {
            controller.safeAreaRegions = []
        }
        controller.onLayout = { [weak self] in self?.scheduleMeasurement() }

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
        scheduleMeasurement()
    }

    private func unmount() {
        guard let controller = hostingController else { return }
        controller.onLayout = nil
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        hostingController = nil
        setMeasuredHeight(0)
    }

    /// Measures on the next turn of the run loop. A layout pass, and SwiftUI's own, can each ask for
    /// a measurement; measuring inside them re-enters layout, so they are coalesced and deferred.
    private func scheduleMeasurement() {
        guard !measurementScheduled else { return }
        measurementScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurementScheduled = false
            guard let controller = self.hostingController, self.bounds.width > 0 else { return }
            let fitted = controller.sizeThatFits(
                in: CGSize(width: self.bounds.width, height: .greatestFiniteMagnitude))
            self.setMeasuredHeight(fitted.height)
        }
    }

    private func setMeasuredHeight(_ height: CGFloat) {
        guard abs(height - measuredHeight) >= 0.5 else { return }
        measuredHeight = height
        invalidateIntrinsicContentSize()
    }
}

/// Reports each layout pass of the SwiftUI content, which is how a campaign arriving or leaving
/// changes the slot's height.
private final class SlotHostingController: UIHostingController<DigiaSlot<EmptyView>> {
    var onLayout: (() -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}
