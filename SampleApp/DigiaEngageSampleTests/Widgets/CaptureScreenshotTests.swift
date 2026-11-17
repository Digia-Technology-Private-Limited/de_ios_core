import Testing
import UIKit
@testable import DigiaEngage

/// The capture screenshot is an 8-bit sRGB PNG at the screen scale, like Android and Flutter.
/// The renderer's default on wide-colour displays is 16 bits per channel (extended sRGB), which
/// makes the PNG about 1.7x larger and can exceed the backend's 5 MB limit.
@MainActor
@Suite("Capture screenshot format", .serialized, .tags(.integration, .capture))
struct CaptureScreenshotTests {
    @Test("the capture screenshot is an 8-bit sRGB PNG at the screen scale")
    func eightBitAtScreenScale() throws {
        let window = Self.window()
        defer { window.isHidden = true }

        let png = try #require(SDKInstance.renderPNG(window: window))
        let image = try #require(UIImage(data: png)?.cgImage)
        #expect(image.bitsPerComponent == 8, "16-bit PNGs are about 1.7x larger")
        #expect(image.width == Int((window.bounds.width * window.screen.scale).rounded()), "full resolution is kept")
        #expect(image.height == Int((window.bounds.height * window.screen.scale).rounded()))
    }

    @Test("an 8-bit capture is smaller than the renderer's 16-bit default of the same screen")
    func smallerThanSixteenBit() throws {
        let window = Self.window()
        defer { window.isHidden = true }

        let png = try #require(SDKInstance.renderPNG(window: window))
        let sixteenBit = try #require(
            UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }.pngData()
        )
        #expect(png.count < sixteenBit.count, "8-bit: \(png.count) bytes, 16-bit: \(sixteenBit.count) bytes")
    }

    /// A photo-like full-screen gradient in a real window scene (drawHierarchy needs one).
    private static func window() -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        let controller = UIViewController()
        let gradient = CAGradientLayer()
        gradient.frame = window.bounds
        gradient.colors = [UIColor.systemRed, .systemTeal, .systemOrange, .systemPurple].map(\.cgColor)
        gradient.startPoint = .zero
        gradient.endPoint = CGPoint(x: 1, y: 1)
        controller.view.layer.addSublayer(gradient)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }
}
