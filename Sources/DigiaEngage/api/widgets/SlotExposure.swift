import SwiftUI
import UIKit

/// Share of the slot that must be on screen for it to count as exposed.
private let exposedFraction: CGFloat = 0.5

/// Sends carousel Step Viewed for the slide on display, only while the slot is exposed. One gate
/// lives per slot and payload, so a re-show of the same slide is quiet and a new payload starts over.
@MainActor
final class CarouselStepGate {
    private let payload: CEPTriggerPayload
    private var index = -1
    private var total = 0
    private var auto = false
    private var sentIndex = -1

    init(payload: CEPTriggerPayload) {
        self.payload = payload
    }

    var exposed = false {
        didSet { send() }
    }

    func onStep(index: Int, total: Int, auto: Bool) {
        self.index = index
        self.total = total
        self.auto = auto
        send()
    }

    private func send() {
        guard exposed, index >= 0, index != sentIndex else { return }
        sentIndex = index
        SDKInstance.shared.reportCarouselStepViewed(
            payload: payload, itemIndex: index + 1, itemTotal: total, auto: auto
        )
    }
}

/// Holds one `CarouselStepGate` for the content and drives it from the slot's exposure.
@MainActor
struct CarouselStepScope<Content: View>: View {
    @State private var gate: CarouselStepGate
    private let content: (CarouselStepGate) -> Content

    init(payload: CEPTriggerPayload, @ViewBuilder content: @escaping (CarouselStepGate) -> Content) {
        _gate = State(initialValue: CarouselStepGate(payload: payload))
        self.content = content
    }

    var body: some View {
        content(gate).background(SlotExposureReader { [gate] in gate.exposed = $0 })
    }
}

/// Reports whether the slot is exposed: the app is active, the slot is in a window with no hidden
/// ancestor, and at least half of it lies inside every clipping ancestor and the window.
private struct SlotExposureReader: UIViewRepresentable {
    let onChange: (Bool) -> Void

    func makeUIView(context _: Context) -> SlotExposureView {
        let view = SlotExposureView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: SlotExposureView, context _: Context) {
        view.onChange = onChange
        view.check()
    }
}

private final class SlotExposureView: UIView {
    var onChange: ((Bool) -> Void)?
    private var exposed = false
    private var scrollObservations: [NSKeyValueObservation] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        let center = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification] {
            center.addObserver(self, selector: #selector(applicationStateChanged), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    // willResignActive arrives before applicationState changes, so read the state on the next turn.
    @objc private func applicationStateChanged() {
        DispatchQueue.main.async { [weak self] in self?.check() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        observeAncestorScrollViews()
        check()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        check()
    }

    func check() {
        let next = UIApplication.shared.applicationState == .active && isHalfVisible()
        guard next != exposed else { return }
        exposed = next
        DispatchQueue.main.async { [weak self] in self?.onChange?(next) }
    }

    private func isHalfVisible() -> Bool {
        guard let window, bounds.width > 0, bounds.height > 0 else { return false }
        var visible = convert(bounds, to: window).intersection(window.bounds)
        var ancestor: UIView? = self
        while let view = ancestor {
            if view.isHidden || view.alpha < 0.01 { return false }
            if view.clipsToBounds {
                visible = visible.intersection(view.convert(view.bounds, to: window))
            }
            ancestor = view.superview
        }
        guard !visible.isNull, !visible.isEmpty else { return false }
        let slotArea = bounds.width * bounds.height
        let windowArea = window.bounds.width * window.bounds.height
        // A slot larger than the screen counts once it fills half the screen.
        return visible.width * visible.height >= min(slotArea, windowArea) * exposedFraction
    }

    private func observeAncestorScrollViews() {
        scrollObservations.removeAll()
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView {
                scrollObservations.append(scrollView.observe(\.contentOffset) { [weak self] _, _ in
                    Task { @MainActor in self?.check() }
                })
            }
            ancestor = view.superview
        }
    }
}
