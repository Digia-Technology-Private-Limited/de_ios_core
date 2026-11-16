import Foundation
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// Native page capture on a real UIKit/SwiftUI runtime (the simulator), one test per way an app
/// builds its screens: UIKit, SwiftUI, SwiftUI inside UIKit, UIKit inside SwiftUI, plus the wrapper
/// cases. Each screen is laid out in a real window and walked the way a capture walks the key
/// window; nothing is uploaded.
@MainActor
@Suite("Native capture: every UI toolkit", .serialized, .tags(.capture, .unit))
struct NativeCaptureToolkitTests {
    private static let detailed = CaptureProfile(
        includeText: true, includeImagesAndMedia: true, includeOtherStructuralNodes: false
    )
    private static let minimal = CaptureProfile(
        includeText: false, includeImagesAndMedia: false, includeOtherStructuralNodes: false
    )

    // MARK: - UIKit

    @Test("a UIKit screen is captured with every element")
    func uiKitScreen() async throws {
        let (window, title) = Self.uiKitWindow()
        defer { window.isHidden = true }

        let minimal = nodes(await walk(window, profile: Self.minimal))
        #expect(ofType(minimal, .interactive).count >= 2, "button and switch are interactive")

        let detailed = nodes(await walk(window, profile: Self.detailed))
        #expect(ofType(detailed, .text).count >= 5, "the title and rows are text")
        #expect(!ofType(detailed, .image).isEmpty, "the image view is an image")
        #expect(detailed.contains { $0.scrollAxis == .vertical }, "the scroll view scrolls vertically")
        #expect(at(detailed, title, in: window).count == 1, "each view is captured once")
    }

    // MARK: - SwiftUI

    @Test("a SwiftUI screen is captured with its elements, not one opaque box")
    func swiftUIScreen() async throws {
        let window = Self.window(UIHostingController(rootView: SwiftUIScreen()))
        defer { window.isHidden = true }

        let minimal = nodes(await walk(window, profile: Self.minimal))
        #expect(ofType(minimal, .interactive).count >= 2, "button and toggle are interactive: \(minimal.map(\.nodeType))")

        let detailed = nodes(await walk(window, profile: Self.detailed))
        #expect(!ofType(detailed, .text).isEmpty, "SwiftUI text is captured: \(detailed.map(\.nodeType))")
        #expect(!ofType(detailed, .image).isEmpty, "the SwiftUI image is captured: \(detailed.map(\.nodeType))")
        #expect(detailed.contains { $0.nodeType == .container }, "the SwiftUI scroll view is a container")
    }

    // SwiftUI builds the accessibility elements inside a ScrollView only for an assistive technology
    // (VoiceOver, automation): outside one, its HostingScrollView reports none and draws the rows
    // straight into layers, so public APIs cannot reach them. Elements outside scroll views are
    // captured (see above). Recorded as a known issue so this test flags it if iOS ever exposes them.
    @Test("rows inside a SwiftUI ScrollView are not captured (iOS exposes them only to assistive tech)")
    func swiftUIScrollViewContent() async throws {
        let window = Self.window(UIHostingController(rootView: SwiftUIScreen()))
        defer { window.isHidden = true }

        let detailed = nodes(await walk(window, profile: Self.detailed))
        withKnownIssue("SwiftUI ScrollView content is only built for assistive technologies") {
            #expect(ofType(detailed, .text).count >= 5, "the 20 rows inside the ScrollView")
        }
    }

    // MARK: - SwiftUI inside UIKit

    @Test("SwiftUI inside UIKit captures both the UIKit views and the SwiftUI content")
    func swiftUIInsideUIKit() async throws {
        let container = UIViewController()
        let header = UILabel()
        header.text = "Classic header"
        let hosting = UIHostingController(rootView: SwiftUIScreen())
        container.addChild(hosting)
        let stack = UIStackView(arrangedSubviews: [header, hosting.view])
        stack.axis = .vertical
        stack.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        container.view.addSubview(stack)
        hosting.didMove(toParent: container)
        let window = Self.window(container)
        defer { window.isHidden = true }

        let detailed = nodes(await walk(window, profile: Self.detailed))
        #expect(at(detailed, header, in: window).count == 1, "the classic header is captured once")
        #expect(ofType(detailed, .interactive).count >= 2, "SwiftUI button and toggle: \(detailed.map(\.nodeType))")
        #expect(!ofType(detailed, .image).isEmpty, "the SwiftUI image")
    }

    // MARK: - UIKit inside SwiftUI

    @Test("UIKit inside SwiftUI captures the embedded view exactly once")
    func uiKitInsideSwiftUI() async throws {
        let label = UILabel()
        label.text = "Classic view inside SwiftUI"
        let window = Self.window(UIHostingController(rootView: VStack {
            Button("SwiftUI button") {}
            EmbeddedLabel(label: label)
        }))
        defer { window.isHidden = true }

        let detailed = nodes(await walk(window, profile: Self.detailed))
        #expect(!ofType(detailed, .interactive).isEmpty, "the SwiftUI button is interactive")
        #expect(
            ofType(at(detailed, label, in: window), .text).count == 1,
            "the embedded UILabel is listed once, not twice"
        )
    }

    // MARK: - Wrappers

    @Test("React Native still captures as reactNative, other wrappers do not capture")
    func wrappers() {
        #expect(SDKInstance.captureBinding(forWrapperBinding: nil) == "native")
        #expect(SDKInstance.captureBinding(forWrapperBinding: "react_native") == "reactNative")
        #expect(SDKInstance.captureBinding(forWrapperBinding: "flutter") == nil)
    }

    // MARK: - Screens

    private struct SwiftUIScreen: View {
        @State private var remember = true
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Welcome to MediHub")
                Button("Buy now") {}
                Image(systemName: "heart.fill").accessibilityLabel("Favourite")
                Toggle("Remember me", isOn: $remember)
                ScrollView {
                    VStack { ForEach(0..<20, id: \.self) { Text("Row \($0)") } }
                }
                .frame(height: 240)
            }
            .padding()
        }
    }

    private struct EmbeddedLabel: UIViewRepresentable {
        let label: UILabel
        func makeUIView(context: Context) -> UILabel { label }
        func updateUIView(_ uiView: UILabel, context: Context) {}
    }

    /// The UIKit screen: title, button, image, switch, and a scroll view of rows.
    private static func uiKitWindow() -> (UIWindow, UILabel) {
        let controller = UIViewController()
        let title = UILabel()
        title.text = "Welcome to MediHub"
        let button = UIButton(type: .system)
        button.setTitle("Buy now", for: .normal)
        let image = UIImageView(image: UIImage(systemName: "heart.fill"))
        let toggle = UISwitch()
        let scroll = UIScrollView()
        let rows = UIStackView(arrangedSubviews: (0..<20).map { index in
            let row = UILabel()
            row.text = "Row \(index)"
            return row
        })
        rows.axis = .vertical
        scroll.addSubview(rows)
        let stack = UIStackView(arrangedSubviews: [title, button, image, toggle, scroll])
        stack.axis = .vertical
        stack.spacing = 12
        stack.frame = CGRect(x: 16, y: 60, width: 358, height: 700)
        controller.view.addSubview(stack)
        let window = window(controller)
        scroll.frame.size.height = 240
        rows.frame = CGRect(x: 0, y: 0, width: 358, height: 20 * 30)
        scroll.contentSize = rows.frame.size
        window.layoutIfNeeded()
        return (window, title)
    }

    private static func window(_ root: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.frame = window.bounds
        root.view.setNeedsLayout()
        root.view.layoutIfNeeded()
        window.layoutIfNeeded()
        return window
    }

    // MARK: - Helpers

    private func walk(_ window: UIWindow, profile: CaptureProfile) async -> CaptureWalkResult {
        // Let SwiftUI finish its first layout pass before walking, as a real capture would.
        try? await Task.sleep(nanoseconds: 150_000_000)
        window.layoutIfNeeded()
        let bounds = window.bounds
        return await CaptureEvidenceWalker.walk(
            root: UIKitCaptureNode(view: window, rootView: window),
            windowBoundsPx: CaptureEdgeRect(
                left: 0, top: 0, right: Int(bounds.width), bottom: Int(bounds.height)
            ),
            profile: profile
        )
    }

    private func nodes(_ result: CaptureWalkResult) -> [CaptureStructuralNode] {
        guard case let .succeeded(nodes, _) = result else {
            Issue.record("expected a successful walk, got \(result)")
            return []
        }
        return nodes
    }

    private func ofType(_ all: [CaptureStructuralNode], _ type: CaptureNodeType) -> [CaptureStructuralNode] {
        all.filter { $0.nodeType == type }
    }

    /// The captured nodes drawn exactly where [view] is, in the window's coordinates.
    private func at(_ all: [CaptureStructuralNode], _ view: UIView, in window: UIWindow) -> [CaptureStructuralNode] {
        let frame = view.convert(view.bounds, to: window)
        return all.filter { node in
            abs(node.rootBoundsPx.left - Int(frame.minX.rounded())) <= 1 &&
                abs(node.rootBoundsPx.top - Int(frame.minY.rounded())) <= 1 &&
                abs(node.rootBoundsPx.right - Int(frame.maxX.rounded())) <= 1 &&
                abs(node.rootBoundsPx.bottom - Int(frame.maxY.rounded())) <= 1
        }
    }
}
