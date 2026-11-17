import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// What native page capture reports for SwiftUI screens in a real window scene, read through the
/// accessibility tree SwiftUI builds while an accessibility client is on (here the test harness's
/// automation): one node per control at the SwiftUI/UIKit boundary.
@Suite("Capture of SwiftUI content", .serialized, .tags(.integration, .capture))
@MainActor
struct CaptureNativeContentTests {
    private static let everything = CaptureProfile(
        includeText: true, includeImagesAndMedia: true, includeOtherStructuralNodes: true
    )
    private static let imagesOnly = CaptureProfile(
        includeText: false, includeImagesAndMedia: true, includeOtherStructuralNodes: false
    )

    // MARK: - One node per control

    // Fails if: the switch and the view or element sharing its rectangle are listed twice, or the
    // hosting view that holds SwiftUI content is listed as one big interactive node.
    @Test("SwiftUI inside UIKit lists its switch once and its hosting view as no control")
    func swiftUIInsideUIKit() async throws {
        let hosting = UIHostingController(rootView: EmbeddedSection())
        let container = UIViewController()
        let header = UILabel()
        header.text = "UIKit header"
        container.addChild(hosting)
        let stack = UIStackView(arrangedSubviews: [header, hosting.view])
        stack.axis = .vertical
        stack.frame = CGRect(x: 0, y: 60, width: 440, height: 600)
        container.view.addSubview(stack)
        hosting.didMove(toParent: container)
        let screen = try await Self.show(container, expectingImages: 1)
        defer { screen.close() }

        let kept = await screen.nodes(Self.everything)
        let hostFrame = hosting.view.convert(hosting.view.bounds, to: screen.window)
        #expect(
            !kept.contains { $0.nodeType == .interactive && $0.rootBoundsPx.isSame(as: Self.edge(hostFrame), within: 1) },
            "the hosting view is not a control"
        )
        let toggle = try #require(Self.find(UISwitch.self, in: screen.window))
        let switchFrame = Self.edge(toggle.convert(toggle.bounds, to: screen.window))
        #expect(
            kept.filter { $0.nodeType == .interactive && $0.rootBoundsPx.isSame(as: switchFrame, within: 1) }.count == 1,
            "one node for the switch"
        )
        let meaningful = kept.filter { $0.nodeType != .container && $0.nodeType != .unknown }
        for (index, node) in meaningful.enumerated() {
            for other in meaningful[(index + 1)...]
            where node.nodeType == other.nodeType && node.rootBoundsPx.isSame(as: other.rootBoundsPx, within: 1) {
                Issue.record("\(node.nodeId) and \(other.nodeId) are both \(node.nodeType) at \(node.rootBoundsPx)")
            }
        }
        // Nothing meaningful went missing: the header, the section's title, button, rows and image.
        #expect(kept.contains { $0.nodeType == .text && $0.rootBoundsPx.top == Int(header.convert(header.bounds, to: screen.window).minY.rounded()) })
        #expect(kept.filter { $0.nodeType == .text }.count >= 4, "header, title and two rows: \(kept.map(\.nodeType))")
        #expect(kept.filter { $0.nodeType == .interactive }.count >= 3, "button, SwiftUI toggle and its UISwitch")
        #expect(kept.contains { $0.nodeType == .image })
    }

    // MARK: - Screens

    private struct EmbeddedSection: View {
        @State private var on = true
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("SwiftUI inside UIKit").font(.headline)
                Image(systemName: "star.fill").resizable().frame(width: 40, height: 40)
                    .accessibilityLabel("Star")
                Button("SwiftUI button") {}.buttonStyle(.borderedProminent)
                Toggle("SwiftUI toggle", isOn: $on)
                ForEach(0..<2, id: \.self) { Text("SwiftUI row \($0)") }
            }
            .padding(.horizontal, 4)
        }
    }

    private struct PlainSwiftUIScreen: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Welcome to MediHub").font(.title)
                Text("Plain SwiftUI body text")
                Button("Buy now") {}
                Image(systemName: "star.fill").resizable().frame(width: 40, height: 40)
                    .accessibilityLabel("Favourite")
            }
            .padding()
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Helpers

    /// A loaded screen in a window of the app's scene.
    private struct LoadedScreen {
        let window: UIWindow

        func close() { window.isHidden = true }

        func nodes(_ profile: CaptureProfile) async -> [CaptureStructuralNode] {
            window.layoutIfNeeded()
            let bounds = window.bounds
            let result = await CaptureEvidenceWalker.walk(
                root: UIKitCaptureNode(view: window, rootView: window),
                windowBoundsPx: CaptureEdgeRect(
                    left: 0, top: 0, right: Int(bounds.width), bottom: Int(bounds.height)
                ),
                profile: profile
            )
            guard case let .succeeded(nodes, _) = result else {
                Issue.record("expected a successful walk, got \(result)")
                return []
            }
            return nodes
        }
    }

    private static func edge(_ rect: CGRect) -> CaptureEdgeRect {
        CaptureEdgeRect(
            left: Int(rect.minX.rounded()), top: Int(rect.minY.rounded()),
            right: Int(rect.maxX.rounded()), bottom: Int(rect.maxY.rounded())
        )
    }

    /// Shows `root` in a window of the app's scene and waits until `expectingImages` image nodes
    /// are listed, the way a person capturing a loaded screen would.
    private static func show(
        _ view: some View, expectingImages count: Int, enableAutomation: Bool = true
    ) async throws -> LoadedScreen {
        try await show(UIHostingController(rootView: view), expectingImages: count, enableAutomation: enableAutomation)
    }

    private static func show(
        _ root: UIViewController, expectingImages count: Int, enableAutomation: Bool = true
    ) async throws -> LoadedScreen {
        if enableAutomation { ComponentTestHost.enableAccessibilityAutomation() }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        window.rootViewController = root
        window.makeKeyAndVisible()
        let screen = LoadedScreen(window: window)
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 100_000_000)
            window.layoutIfNeeded()
            if count == 0 { continue }
            let shown = await screen.nodes(Self.imagesOnly).filter { $0.nodeType == .image }.count
            if shown >= count { break }
        }
        return screen
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }
}
}
