import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// What the nudge, canvas and banner behaviour suites share on top of `SdkHarness`: showing a
/// nudge over a plain app screen, reading where things are drawn, and touching the screen at a
/// point or dragging across it — real touches, as `SdkHarness+Touch.swift` taps.
extension SdkHarness {

    /// Boots the SDK with [campaign], mounts a plain app screen, delivers the campaign and waits
    /// until [title] is on screen and has stopped moving (the entry animation is over).
    static func showNudge(_ campaign: [String: Any], title: String) async throws -> SdkHarness {
        let sdk = try await SdkHarness.start(campaign)
        try sdk.mount { Text("App home") }
        try sdk.deliver(keyOf(campaign))
        try await sdk.waitUntilSteady(text: title)
        return sdk
    }

    /// The screen size: the harness window, ``SdkHarness/screen``.
    var screenSize: CGSize { window?.bounds.size ?? .zero }

    /// Where the element that shows [text] is drawn, in window coordinates.
    func frame(text: String) -> CGRect? {
        frame(of: element(text: text))
    }

    /// Where the canvas element authored with [id] is drawn, in window coordinates.
    func frame(id: String) -> CGRect? {
        frame(of: element(id: id))
    }

    /// The close button the SDK draws for a nudge (`NudgeCloseButton`, read out as "Close").
    var closeButton: NSObject? {
        guard let window else { return nil }
        return Self.find(in: window) {
            $0.accessibilityLabel == "Close" && $0.accessibilityTraits.contains(.button)
        }
    }

    /// Where the nudge's close button is drawn, in window coordinates.
    var closeButtonFrame: CGRect? { frame(of: closeButton) }

    func frame(of element: NSObject?) -> CGRect? {
        guard let window, let frame = element?.accessibilityFrame, !frame.isEmpty else { return nil }
        return window.convert(frame, from: window.screen.coordinateSpace)
    }

    /// Waits until [text] is on screen and its frame has held for 400 ms, as `tap(id:)` does
    /// before touching.
    func waitUntilSteady(text: String, timeout: TimeInterval = 4) async throws {
        try await waitUntilSteady("\(text) settled on screen", timeout: timeout) { self.frame(text: text) }
    }

    func waitUntilSteady(
        _ what: String, timeout: TimeInterval = 4, _ read: @escaping () -> CGRect?
    ) async throws {
        var last: CGRect?
        var steadyReads = 0
        try await waitUntil(what, timeout: timeout) {
            guard let frame = read() else { steadyReads = 0; return false }
            steadyReads = frame == last ? steadyReads + 1 : 0
            last = frame
            return steadyReads >= 8 // 8 reads, 50 ms apart
        }
    }

    /// A real tap at [point], in window coordinates.
    func tap(at point: CGPoint) throws {
        try TouchSynthesizer.tap(at: point, in: try #require(window))
    }

    /// A real tap at the centre of the nudge's close button, once it has stopped moving.
    func tapCloseButton() async throws {
        try await waitUntilSteady("the close button settled on screen") { self.closeButtonFrame }
        let frame = try #require(closeButtonFrame)
        try tap(at: CGPoint(x: frame.midX, y: frame.midY))
    }

    /// A finger put down at [start], moved by [offset] in [steps] even moves of 16 ms each, and,
    /// unless [release] is false, lifted there. Returns the drag so a held one can be released.
    @discardableResult
    func drag(
        from start: CGPoint, by offset: CGVector, steps: Int = 20, release: Bool = true
    ) throws -> TouchSynthesizer.Finger {
        let drag = try TouchSynthesizer.Finger(window: try #require(window), start: start)
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            try drag.move(to: CGPoint(x: start.x + offset.dx * fraction, y: start.y + offset.dy * fraction))
        }
        if release { try drag.release() }
        return drag
    }
}

/// Where a piece of the app's own screen (a `DigiaSlot`) is laid out, read through a
/// `GeometryReader`: a banner has no accessibility id of its own to find it by.
@MainActor
final class NudgeCanvasFrameProbe {
    private(set) var frame: CGRect = .zero

    func update(_ frame: CGRect) { self.frame = frame }
}

extension View {
    /// Reports this view's frame, in window coordinates, to [probe] whenever it changes.
    func nudgeCanvasFrame(_ probe: NudgeCanvasFrameProbe) -> some View {
        background(GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            Color.clear
                .onAppear { probe.update(frame) }
                .onChange(of: frame) { probe.update($0) }
        })
    }
}

extension SdkHarness {
    /// The window as drawn now, as RGBA pixels at 1 px per point.
    func renderedPixels() throws -> NudgeCanvasPixels {
        let window = try #require(window)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return try NudgeCanvasPixels(try #require(image.cgImage))
    }
}

/// A rendered window's pixels, for asking what colour is drawn where.
struct NudgeCanvasPixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.bytes = bytes
    }

    /// The (r, g, b) at [point], in window points.
    func color(at point: CGPoint) -> (r: Int, g: Int, b: Int) {
        let x = min(max(Int(point.x), 0), width - 1)
        let y = min(max(Int(point.y), 0), height - 1)
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    /// How many pixels inside [rect] satisfy [match].
    func count(in rect: CGRect, where match: ((r: Int, g: Int, b: Int)) -> Bool) -> Int {
        var found = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) where match(color(at: CGPoint(x: x, y: y))) {
                found += 1
            }
        }
        return found
    }
}
