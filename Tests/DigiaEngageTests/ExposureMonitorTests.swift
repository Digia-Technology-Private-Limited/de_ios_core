import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// `anchor_visible` and `slot_visible` fire on each appearance (Flutter `SlotExposure`).
@MainActor
@Suite("Exposure monitor", .serialized)
struct ExposureMonitorTests {
    private let clip = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test("half the view inside the clip is exposed; less is not")
    func halfThreshold() {
        #expect(ExposureGeometry.isExposed(rect: CGRect(x: 0, y: 50, width: 100, height: 100), clip: clip))
        #expect(!ExposureGeometry.isExposed(rect: CGRect(x: 0, y: 51, width: 100, height: 100), clip: clip))
    }

    @Test("a view larger than the clip counts once it fills half the clip")
    func largerThanClip() {
        #expect(ExposureGeometry.isExposed(rect: CGRect(x: 0, y: -50, width: 100, height: 1_000), clip: clip))
        #expect(ExposureGeometry.isExposed(rect: CGRect(x: 0, y: 50, width: 100, height: 1_000), clip: clip))
        #expect(!ExposureGeometry.isExposed(rect: CGRect(x: 0, y: 51, width: 100, height: 1_000), clip: clip))
    }

    @Test("an empty view is exposed once its top-left point is inside the clip")
    func emptyView() {
        #expect(ExposureGeometry.isExposed(rect: CGRect(x: 10, y: 99, width: 100, height: 0), clip: clip))
        #expect(!ExposureGeometry.isExposed(rect: CGRect(x: 10, y: 100, width: 100, height: 0), clip: clip))
        #expect(!ExposureGeometry.isExposed(rect: CGRect(x: 10, y: 10, width: 0, height: 0), clip: .zero))
    }

    @Test("a re-register is no new appearance; leaving and returning, or the app re-activating, is")
    func firesOnEachAppearanceOnly() {
        let monitor = ExposureMonitor()
        var active = true
        monitor.isAppActive = { active }
        let window = ComponentTestHost.makeWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.addSubview(view)
        var fired = 0

        monitor.track(view, tag: "anchor:cta") { fired += 1 }
        monitor.check()
        #expect(fired == 1)

        monitor.track(view, tag: "anchor:cta") { fired += 1 }
        monitor.check()
        #expect(fired == 1)

        view.removeFromSuperview()
        monitor.check()
        window.addSubview(view)
        monitor.check()
        #expect(fired == 2)

        active = false
        monitor.check()
        active = true
        monitor.check()
        #expect(fired == 3)
        window.isHidden = true
    }

    /// Height 0 is the React Native slot bridge's hosting view while the slot is empty.
    @Test("an empty slot is exposed, in a full-size or a zero-height hosting view", arguments: [844.0, 0.0])
    func emptySlotIsExposed(hostHeight: CGFloat) async {
        let monitor = ExposureMonitor.shared
        monitor.resetForTesting()
        monitor.isAppActive = { true }
        defer { monitor.resetForTesting() }
        let window = ComponentTestHost.makeWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: hostHeight))
        window.addSubview(container)
        let host = UIHostingController(rootView: DigiaSlot("empty_rn_slot"))
        host.view.frame = container.bounds
        container.addSubview(host.view)
        host.view.layoutIfNeeded()
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        monitor.check()

        #expect(monitor.exposures(tag: "slot:empty_rn_slot") == [true])
        host.view.removeFromSuperview()
        window.isHidden = true
    }
}
