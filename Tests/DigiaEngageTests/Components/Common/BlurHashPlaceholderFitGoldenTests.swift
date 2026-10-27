import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// Pixel goldens proving `BlurHashPlaceholderView` follows the image's fit.
///
/// Rendering uses SwiftUI `ImageRenderer` (iOS 16+, scale 2) into a fixed
/// 300x150 frame on a black background — no network, no runloop waits — so the
/// reference PNGs are deterministic.
@Suite("BlurHash placeholder fit goldens", .tags(.golden, .inline))
struct BlurHashPlaceholderFitGoldenTests {
    /// Wide-frame hash shared by every state below; decoded 32x32 (square), so
    /// `.fill` crops top/bottom while `.fit` letterboxes left/right.
    private static let hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
    private static let frame = CGSize(width: 300, height: 150)

    @Test("fill content mode covers the full-bleed frame") @MainActor
    func fillRendersFullBleed() throws {
        let image = try #require(render(contentMode: .fill))
        assertVisualGolden(
            matching: image,
            precision: 0.999,
            perceptualPrecision: 0.98,
            named: "fill-fullbleed"
        )
    }

    @Test("fit content mode letterboxes on black") @MainActor
    func fitRendersLetterbox() throws {
        let image = try #require(render(contentMode: .fit))
        assertVisualGolden(
            matching: image,
            precision: 0.999,
            perceptualPrecision: 0.98,
            named: "fit-letterbox"
        )
    }

    @Test("nil content mode stretches to fill") @MainActor
    func stretchRendersFill() throws {
        let image = try #require(render(contentMode: nil))
        assertVisualGolden(
            matching: image,
            precision: 0.999,
            perceptualPrecision: 0.98,
            named: "stretch-fill"
        )
    }

    @Test("fit-string init renders pixel-comparable to the matching content mode") @MainActor
    func fitInitMatchesContentMode() throws {
        let pairs: [(fit: String, mode: ContentMode?)] = [
            ("cover", .fill),
            ("contain", .fit),
            ("fill", nil),
        ]
        for pair in pairs {
            let expected = try #require(render(contentMode: pair.mode))
            let actual = try #require(render(fit: pair.fit))
            let expectedGrid = try #require(brightnessGrid(expected))
            let actualGrid = try #require(brightnessGrid(actual))
            let worst = zip(expectedGrid, actualGrid).map { abs($0 - $1) }.max() ?? .infinity
            #expect(
                worst < 0.03,
                "fit '\(pair.fit)' diverged from contentMode \(String(describing: pair.mode)) (worst Δ=\(worst))"
            )
        }

        // Structural: the fit frame letterboxes (dark bars), while the
        // fill/stretch frames cover the edges with decoded image content.
        let fit = try #require(render(contentMode: .fit))
        let fill = try #require(render(contentMode: .fill))
        #expect(sampleBrightness(fit, x: 0.03, y: 0.5) < 0.08, "fit should letterbox the left edge on black")
        #expect(sampleBrightness(fill, x: 0.03, y: 0.5) > 0.12, "fill should cover the left edge with image content")
        #expect(sampleBrightness(fit, x: 0.5, y: 0.5) > 0.12, "fit should still show image content mid-frame")
    }

    // MARK: - Rendering

    @MainActor
    private func render(contentMode: ContentMode?) -> UIImage? {
        render(BlurHashPlaceholderView(
            placeholder: ImagePlaceholder(type: .blurhash, blurHash: Self.hash),
            contentMode: contentMode
        ))
    }

    @MainActor
    private func render(fit: String) -> UIImage? {
        render(BlurHashPlaceholderView(
            placeholder: ImagePlaceholder(type: .blurhash, blurHash: Self.hash),
            fit: fit
        ))
    }

    @MainActor
    private func render(_ placeholder: BlurHashPlaceholderView) -> UIImage? {
        // ImageRenderer needs iOS 16+; the pinned simulator is well past that,
        // and `try #require` fails loudly anywhere older.
        guard #available(iOS 16.0, *) else { return nil }
        let view = ZStack {
            Color.black
            placeholder
        }
        .frame(width: Self.frame.width, height: Self.frame.height)
        var renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: Self.frame.width, height: Self.frame.height)
        return renderer.uiImage
    }

    // MARK: - Pixel sampling

    /// Luminance grid (row-major) over the image, each cell in 0...1.
    private func brightnessGrid(_ image: UIImage, columns: Int = 8, rows: Int = 4) -> [Double]? {
        guard let pixels = rgbaPixels(image) else { return nil }
        var grid: [Double] = []
        grid.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                grid.append(sampleBrightness(
                    pixels,
                    x: (Double(column) + 0.5) / Double(columns),
                    y: (Double(row) + 0.5) / Double(rows)
                ))
            }
        }
        return grid
    }

    private func sampleBrightness(_ image: UIImage, x: Double, y: Double) -> Double {
        guard let pixels = rgbaPixels(image) else { return .nan }
        return sampleBrightness(pixels, x: x, y: y)
    }

    private func sampleBrightness(
        _ pixels: (width: Int, height: Int, bytes: [UInt8]),
        x: Double,
        y: Double
    ) -> Double {
        let px = min(pixels.width - 1, max(0, Int(x * Double(pixels.width))))
        let py = min(pixels.height - 1, max(0, Int(y * Double(pixels.height))))
        let offset = (py * pixels.width + px) * 4
        let r = Double(pixels.bytes[offset])
        let g = Double(pixels.bytes[offset + 1])
        let b = Double(pixels.bytes[offset + 2])
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
    }

    /// Normalizes any source colorspace to 8-bit RGBA so sampling is exact.
    private func rgbaPixels(_ image: UIImage) -> (width: Int, height: Int, bytes: [UInt8])? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (width, height, bytes) : nil
    }
}
