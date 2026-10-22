import SnapshotTesting
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

/// Draws a campaign fixture through the real SDK and compares the settled frame with
/// `__Snapshots__/<surface>/<name>.png`.
///
/// The comparison is `swift-snapshot-testing`'s image diffing. The file layout is ours, so a baseline is
/// `<fixture>.png` as on Flutter, and recording is a plain write that does not fail the run.
private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private extension Dictionary where Key == String {
    /// The first boolean found under `key`, at any depth.
    func deepBool(_ key: String) -> Bool? {
        func walk(_ value: Any?) -> Bool? {
            switch value {
            case let dict as [String: Any]:
                if let found = dict[key] as? Bool { return found }
                return dict.values.lazy.compactMap(walk).first
            case let array as [Any]:
                return array.lazy.compactMap(walk).first
            default: return nil
            }
        }
        return walk(self)
    }

    /// The first string found under `key`, at any depth.
    func deepString(_ key: String) -> String? {
        func walk(_ value: Any?) -> String? {
            switch value {
            case let dict as [String: Any]:
                if let found = dict[key] as? String { return found }
                return dict.values.lazy.compactMap(walk).first
            case let array as [Any]:
                return array.lazy.compactMap(walk).first
            default: return nil
            }
        }
        return walk(self)
    }
}

@MainActor
enum GoldenHarness {
    /// Flutter accepts a frame whose differing pixels are at most 0.4% of it. `precision` is the share of
    /// pixels that must match, so 0.996 is the same bound. `perceptualPrecision` lets a pixel differ
    /// by the 2% the eye cannot see, which absorbs anti-aliasing noise that Flutter's byte compare would
    /// count as a miss.
    static let precision: Float = 0.996
    static let perceptualPrecision: Float = 0.98

    /// Pixels per point: the Flutter goldens are 1x, but a phone is 3x and a 1x frame hides hairlines.
    static let scale: CGFloat = 3

    static var isRecording: Bool { ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "true" }

    private static let snapshots = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("__Snapshots__")

    /// What the campaign is shown over.
    enum Host {
        /// Striped screen so barrier colour, transparency and safe-area gaps show in the golden instead of
        /// blending into a flat background. For nudges and surveys.
        case striped
        /// A scrolling screen with the slot between two content blocks, so the card's margins and rounded
        /// corners show against the page behind it. For inline campaigns.
        case slot(String)
        /// A screen carrying every anchor the guide fixtures target, at fixed positions, so each tooltip and
        /// cutout lands in the same place on every run. A fixture naming an anchor not listed here is not shown.
        case guide
    }

    /// The screen name the host reports; anchorless fixtures target page `home`.
    static let guideScreenName = "home"

    struct StripedHost: View {
        var body: some View {
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { i in
                    (i.isMultiple(of: 2) ? Color(red: 0.149, green: 0.651, blue: 0.604) : Color(red: 1, green: 0.792, blue: 0.157))
                }
            }
            .ignoresSafeArea()
        }
    }

    struct GuideHost: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    DigiaAnchor(anchorKey: "home_header_search") { target("Search", height: 44) }
                    DigiaAnchor(anchorKey: "wishlist_icon_btn") { target("W", height: 44).frame(width: 44) }
                }
                DigiaAnchor(anchorKey: "category_chips") { target("Categories", height: 40) }.padding(.top, 16)
                DigiaAnchor(anchorKey: "home_carousel") { target("Carousel", height: 180) }.padding(.top, 140)
                DigiaAnchor(anchorKey: "pdp_seller_info") { target("Seller info", height: 64) }.padding(.top, 120)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(red: 0.925, green: 0.937, blue: 0.945).ignoresSafeArea())
        }

        private func target(_ label: String, height: CGFloat) -> some View {
            Text(label).foregroundColor(.white)
                .frame(maxWidth: .infinity).frame(height: height)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.149, green: 0.651, blue: 0.604)))
        }
    }

    struct SlotHost: View {
        let slotKey: String

        var body: some View {
            ScrollView {
                VStack(spacing: 0) {
                    Color(red: 0.149, green: 0.651, blue: 0.604).frame(height: 120)
                    DigiaSlot(slotKey) { Color.clear }
                    Color(red: 1, green: 0.792, blue: 0.157).frame(height: 120)
                }
            }
            .background(Color(red: 0.925, green: 0.937, blue: 0.945).ignoresSafeArea())
        }
    }

    /// A server clock 2 d 03:45:12.5 before the Test Kit timers' 2030-01-01 deadline at the moment the frame
    /// is taken, so a countdown reads 2 d 03:45:13. Countdowns round up to the next second and the clock runs
    /// on real time, so the capture is aimed at the middle of a second, which leaves +-0.5 s of run-to-run
    /// slack. `expectedElapsed` is how long after the bundle is served the frame is taken.
    static func timerServerTimeMs(expectedElapsed: TimeInterval) -> Int64 {
        let deadline: Int64 = 1_893_456_000_000  // 2030-01-01T00:00:00Z
        let remaining = ((2 * 24 + 3) * 3600 + 45 * 60 + 12) * 1000 + 500 + Int64(expectedElapsed * 1000)
        return deadline - remaining
    }

    /// Shows `fixture` over `host` and compares it with `goldens/<surface>/<fixture>.png`.
    static func expectFixtureGolden(
        _ fixture: WorkspaceFixtures.Campaign,
        surface: String,
        host: Host = .striped,
        settle: TimeInterval = 1.5,
        backend: StubBackend.Options = StubBackend.Options(),
        sendFallbackVariables: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let sdk: SdkHarness
        switch host {
        case .striped: sdk = try await SdkHarness.start([fixture], backend: backend) { StripedHost() }
        case .slot(let key): sdk = try await SdkHarness.start([fixture], backend: backend) { SlotHost(slotKey: key) }
        case .guide: sdk = try await SdkHarness.start([fixture], backend: backend) { GuideHost() }
        }
        defer { sdk.tearDown() }
        // A screen-targeted campaign only shows while the host is on one of its screens; an anchorless guide
        // resolves its geometry only on the page it was captured on.
        if let screen = fixture.targetScreens.first { Digia.setCurrentScreen(name: screen) }
        else if case .guide = host { Digia.setCurrentScreen(name: guideScreenName) }
        // `sendFallbackVariables`: the CEP supplies every runtime variable, here with the fixture's own fallback.
        let presentation = sdk.cep.deliver(fixture.campaignKey, variables: sendFallbackVariables ? fixture.fallbackVariables : nil)
        await sdk.settle(settle)
        if let outcome = presentation?.outcome.settledValue {
            // A campaign the SDK turns away shows nothing; the golden is then the bare host, and only a
            // fixture named for that (`..._shows_nothing`) may do so.
            #expect(fixture.name.hasSuffix("shows_nothing"), "the campaign was turned away: \(outcome)", sourceLocation: sourceLocation)
        }
        expect(sdk.window, surface: surface, name: fixture.name, sourceLocation: sourceLocation)
    }

    /// Delivers a guide the SDK must not draw and asserts it stays off screen, as every Engage SDK does when the
    /// first anchor is absent or the target cannot be placed.
    static func expectGuideNotShown(
        _ fixture: WorkspaceFixtures.Campaign,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let sdk = try await SdkHarness.start([fixture]) { GuideHost() }
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: fixture.targetScreens.first ?? guideScreenName)
        let hostOnly = render(sdk.window)
        sdk.cep.deliver(fixture.campaignKey)
        // Past the manager's two-second wait for a missing anchor.
        await sdk.settle(2.6)
        #expect(SDKInstance.shared.guideOrchestrator.state == nil, "\(fixture.name) is showing a guide; it now needs a golden", sourceLocation: sourceLocation)
        #expect(render(sdk.window).pngData() == hostOnly.pngData(), "\(fixture.name) changed the screen; it now needs a golden", sourceLocation: sourceLocation)
    }

    /// Delivers a campaign that has no step the SDK can draw, and asserts the SDK turns it away at once.
    static func expectGuideDropped(
        _ fixture: WorkspaceFixtures.Campaign,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let sdk = try await SdkHarness.start([fixture]) { GuideHost() }
        defer { sdk.tearDown() }
        let presentation = try #require(sdk.cep.deliver(fixture.campaignKey), sourceLocation: sourceLocation)
        await sdk.settle(0.5)
        guard case .dropped = presentation.outcome.settledValue else {
            Issue.record("\(fixture.name) was not dropped; it now needs a golden", sourceLocation: sourceLocation)
            return
        }
    }

    /// Shows an overlay campaign (a PiP or a story floater) over the striped host and compares its two states:
    /// the small window (`<fixture>-collapsed.png`) and the full-screen one a real tap on the window opens
    /// (`<fixture>-expanded.png`). A campaign that starts expanded is captured there first.
    ///
    /// The window's own position is not known to the test: it is found as the pixels that differ from the bare
    /// host, so the tap lands on whatever the SDK drew.
    static func expectOverlayGolden(
        _ fixture: WorkspaceFixtures.Campaign,
        surface: String,
        settle: TimeInterval = 2,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let fixture = fixture.holdingTimers()
        let sdk = try await SdkHarness.start([fixture]) { StripedHost() }
        defer { sdk.tearDown() }
        sdk.useStillVideo()
        if let screen = fixture.targetScreens.first { Digia.setCurrentScreen(name: screen) }
        let hostOnly = render(sdk.window)
        let presentation = sdk.cep.deliver(fixture.campaignKey)
        await sdk.settle(settle)
        #expect(presentation?.outcome.settledValue == nil, "the campaign was turned away: \(String(describing: presentation?.outcome.settledValue))", sourceLocation: sourceLocation)

        let startsExpanded = fixture.json.deepString("initialState") == "expanded"
        let first = startsExpanded ? "expanded" : "collapsed"
        expect(sdk.window, surface: surface, name: "\(fixture.name)-\(first)", sourceLocation: sourceLocation)
        if startsExpanded {
            // A real tap on the collapse button: the first of the chrome's buttons, or the second when the close
            // button is on the left.
            let buttons = UIProbe.buttonFrames(in: sdk.window).filter { $0.minY < 160 }
            let closeOnLeft = fixture.json.deepBool("closeOnLeft") == true
            guard let button = buttons.indices.contains(closeOnLeft ? 1 : 0) ? buttons[closeOnLeft ? 1 : 0] : nil else {
                Issue.record("no collapse button in the expanded chrome", sourceLocation: sourceLocation)
                return
            }
            try TouchSynthesizer.tap(at: CGPoint(x: button.midX, y: button.midY), in: sdk.window)
            await sdk.settle(1.5)
            expect(sdk.window, surface: surface, name: "\(fixture.name)-collapsed", sourceLocation: sourceLocation)
            return
        }

        guard let point = changedRegion(from: hostOnly, to: render(sdk.window))?.center else {
            Issue.record("nothing was drawn over the host, so there is no window to tap", sourceLocation: sourceLocation)
            return
        }
        try TouchSynthesizer.tap(at: CGPoint(x: point.x, y: point.y), in: sdk.window)
        await sdk.settle(2.5)
        expect(sdk.window, surface: surface, name: "\(fixture.name)-expanded", sourceLocation: sourceLocation)
    }

    /// The bounding box, in points, of the pixels that differ between two renders of the window.
    private static func changedRegion(from before: UIImage, to after: UIImage) -> CGRect? {
        guard let a = before.cgImage, let b = after.cgImage, a.width == b.width, a.height == b.height else { return nil }
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        let (p, q) = (pixels(a), pixels(b))
        var minX = a.width, minY = a.height, maxX = -1, maxY = -1
        for y in 0..<a.height {
            for x in 0..<a.width {
                let i = (y * a.width + x) * 4
                if abs(Int(p[i]) - Int(q[i])) + abs(Int(p[i + 1]) - Int(q[i + 1])) + abs(Int(p[i + 2]) - Int(q[i + 2])) > 12 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    static func render(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    static func expect(_ window: UIWindow, surface: String, name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let image = render(window)
        let baseline = snapshots.appendingPathComponent(surface).appendingPathComponent("\(name).png")

        if isRecording {
            do {
                try FileManager.default.createDirectory(at: baseline.deletingLastPathComponent(), withIntermediateDirectories: true)
                try image.pngData()!.write(to: baseline)
            } catch {
                Issue.record("could not record \(baseline.path): \(error)", sourceLocation: sourceLocation)
            }
            return
        }
        guard let data = try? Data(contentsOf: baseline), let expected = UIImage(data: data, scale: scale) else {
            Issue.record("no baseline at \(baseline.path); record it with RECORD_SNAPSHOTS=true ./run-tests.sh golden", sourceLocation: sourceLocation)
            return
        }
        let diffing = Snapshotting<UIImage, UIImage>.image(precision: precision, perceptualPrecision: perceptualPrecision, scale: scale).diffing
        guard let (message, _) = diffing.diff(expected, image) else { return }
        Attachment.record(image.pngData()!, named: "\(name)-actual.png")
        Attachment.record(data, named: "\(name)-expected.png")
        Issue.record("\(surface)/\(name): \(message)", sourceLocation: sourceLocation)
    }
}
