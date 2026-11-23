import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// `DigiaSlotView`, the UIKit slot. The screen is plain UIKit: the slot pinned to the top and sides of
/// a view controller's view, with no height of its own, as the slot's documentation tells a customer
/// to lay it out. There is deliberately no host in the window: an inline campaign is drawn by the
/// slot alone.
@Suite("DigiaSlotView", .serialized, .tags(.integration, .inline))
@MainActor
struct DigiaSlotViewTests {

    private final class SlotScreen: UIViewController {
        let slot = DigiaSlotView()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .white
            slot.placementKey = "home_banner"
            slot.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(slot)
            NSLayoutConstraint.activate([
                slot.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                slot.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                slot.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
    }

    // Fails if: `DigiaSlotView` stops taking `sizeThatFits` of its content as its height (`scheduleMeasurement`).
    // A campaign arriving changes only the SwiftUI content inside the slot, never the slot's own view, so
    // the slot has to measure again by itself; it does on its own layout pass and on the content's.
    @Test("a slot takes no space until its campaign arrives, then grows to the content's height")
    func slotSizesToItsCampaign() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("campaigns/inline_banner/inline_banner_home.json"))
        defer { sdk.tearDown() }
        let screen = SlotScreen()
        let window = ComponentTestHost.makeWindow(frame: CGRect(origin: .zero, size: SdkHarness.screen))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        sdk.window = window
        ComponentTestHost.drainRunLoop(for: 0.3)
        #expect(screen.slot.intrinsicContentSize.height == 0)

        try sdk.deliver("test_inline_banner_home")

        try await sdk.waitUntil("the slot has taken the banner's height") {
            screen.slot.intrinsicContentSize.height > 0
        }
    }
}
}
