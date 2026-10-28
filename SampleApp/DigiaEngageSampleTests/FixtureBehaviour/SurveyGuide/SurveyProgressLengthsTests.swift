import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// `survey_branch_progress_lengths`: the progress bar is segmented, one segment per question on
/// the route the respondent is currently on. The first question's answer decides between a short
/// route (two questions) and a long one (three questions, with a note between the last two that is
/// not a question). The bar must grow when the long route is chosen without shrinking the part
/// already shown, and must not count the note.
///
/// The bar is SwiftUI shapes, which no view or accessibility element stands for, so the test reads
/// it the way the respondent does: from the pixels on screen, finding the runs of the fixture's
/// filled and track colours across the bar.
///
/// Port of `flutter/core/test/fixture_behaviour/survey_progress_lengths_test.dart`.
@Suite("Survey: progress lengths on a branching route", .serialized, .tags(.integration, .behaviour, .survey))
@MainActor
struct SurveyProgressLengthsTests {

    private static let key = "test_survey_branch_progress_lengths"
    private static let root = "Do you shop online weekly?"

    private func open() async throws -> SdkHarness {
        let sdk = try await SdkHarness.surveyGuideStart(["campaigns/survey/survey_branch_progress_lengths.json"])
        try await sdk.openSurvey(Self.key, firstText: Self.root)
        return sdk
    }

    /// Waits until the bar shows [count] segments with [filled] of them filled, and returns their
    /// widths relative to the first.
    private func bar(_ sdk: SdkHarness, below prompt: String, count: Int, filled: Int) async throws -> [CGFloat] {
        let window = try #require(sdk.window)
        func read() -> [ProgressSegmentSG] {
            guard let element = sdk.element(text: prompt) else { return [] }
            let frame = window.convert(element.accessibilityFrame, from: window.screen.coordinateSpace)
            return ProgressSegmentSG.read(in: window, above: frame)
        }
        var segments: [ProgressSegmentSG] = []
        do {
            try await sdk.waitUntil("\(count) segments, \(filled) filled") {
                segments = read()
                return segments.count == count && segments.filter(\.filled).count == filled
            }
        } catch {
            Issue.record("the bar read \(segments)")
            throw error
        }
        // A scene change animates the bar's rect; read it again once it has settled.
        try await sdk.settle(0.5)
        segments = read()
        #expect(segments.count == count)
        let first = try #require(segments.first?.width)
        return segments.map { $0.width / first }
    }

    private func expectRatios(_ ratios: [CGFloat], _ expected: [CGFloat], tolerance: CGFloat = 0.03) {
        #expect(ratios.count == expected.count, "ratios \(ratios)")
        for (actual, wanted) in zip(ratios, expected) {
            #expect(abs(actual - wanted) <= tolerance, "ratios \(ratios), expected \(expected)")
        }
    }

    // Fails if: survey_view_model.swift `progressSegmentWeights` divides the whole bar evenly
    // instead of only the unfilled remainder (`(1 - previous) / Double(remainingCount)`), or
    // `progressNodeIds` stops following the answered route.
    @Test("choosing the longer route adds segments without shrinking the part already shown, and choosing the shorter route takes them away")
    func routeChangesSegments() async throws {
        let sdk = try await open()
        defer { sdk.tearDown() }

        // Unanswered, the route is the fallback one: two questions, two halves.
        expectRatios(try await bar(sdk, below: Self.root, count: 2, filled: 1), [1, 1])

        // Yes leads to three questions. The first segment keeps its half and the unfilled
        // remainder is split in two.
        try await sdk.tapExact("Yes")
        expectRatios(try await bar(sdk, below: Self.root, count: 3, filled: 1), [1, 0.5, 0.5])

        // Changing the answer to No returns to the short route.
        try await sdk.tapExact("No")
        expectRatios(try await bar(sdk, below: Self.root, count: 2, filled: 1), [1, 1])
    }

    // Fails if: survey_view_model.swift `syncProgressAfterNavigation` stops appending
    // `previous + (1 - previous) / Double(remainingSegments)`, or `isIncludedInProgress` counts a
    // content scene (`!countQuestionsOnly || canvasScene.kind == .question`).
    @Test("later segments keep the width the earlier ones left them, and a note between questions is not counted")
    func laterSegmentsKeepWidths() async throws {
        let sdk = try await open()
        defer { sdk.tearDown() }
        try await sdk.tapExact("Yes")
        try await sdk.surveyNext()

        // Second question of three: the second segment takes half of what was left, so the widths
        // are 2:1:1.
        try await sdk.waitUntil("the long route") { sdk.isShowing("Long route 1 of 2") }
        expectRatios(try await bar(sdk, below: "Long route 1 of 2", count: 3, filled: 2), [1, 0.5, 0.5])

        try await sdk.tapExact("Yes")
        try await sdk.surveyNext()

        // The note is not a question: still three segments, still two filled.
        try await sdk.waitUntil("the note") { sdk.isShowing("A note between questions") }
        _ = try await bar(sdk, below: "A note between questions", count: 3, filled: 2)

        try await sdk.surveyNext()
        try await sdk.waitUntil("the last question") { sdk.isShowing("Long route 2 of 2") }
        expectRatios(try await bar(sdk, below: "Long route 2 of 2", count: 3, filled: 3), [1, 0.5, 0.5])
    }
}
}

/// One segment of the survey's segmented progress bar, read from the screen's pixels.
struct ProgressSegmentSG: CustomStringConvertible {
    let width: CGFloat
    let filled: Bool

    var description: String { "\(filled ? "filled" : "track")(\(Int(width)))" }

    /// The fixture's progress colours: filled `color` and `trackColor`.
    private static let filledRGB: (Int, Int, Int) = (0x28, 0x3F, 0x37)
    private static let trackRGB: (Int, Int, Int) = (0xDD, 0xE0, 0xD5)

    /// Snapshots [window] and reads the bar: the nearest band of rows above [prompt] (the
    /// question's frame; the bar sits between the dialog's top and its prompt) made of the
    /// fixture's filled and track colours, split into runs at the gaps between segments.
    @MainActor
    static func read(in window: UIWindow, above prompt: CGRect) -> [ProgressSegmentSG] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let cg = image.cgImage else { return [] }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        func kind(_ x: Int, _ y: Int) -> Bool? {
            let i = (y * width + x) * 4
            let rgb = (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
            func near(_ c: (Int, Int, Int)) -> Bool {
                abs(rgb.0 - c.0) <= 14 && abs(rgb.1 - c.1) <= 14 && abs(rgb.2 - c.2) <= 14
            }
            if near(filledRGB) { return true }
            if near(trackRGB) { return false }
            return nil
        }
        let scale = CGFloat(width) / window.bounds.width
        // The bar starts a little left of the prompt and ends before the prompt's right edge.
        let minX = max(0, Int((prompt.minX - prompt.width * 0.1) * scale))
        let maxX = min(width, Int(prompt.maxX * scale))
        func barPixels(_ y: Int) -> Int { (minX..<maxX).filter { kind($0, y) != nil }.count }

        // The bar spans most of the prompt's width; scan up from the prompt for it.
        let threshold = Int(prompt.width * scale * 0.5)
        let promptTop = min(height - 1, Int(prompt.minY * scale))
        guard let bottom = stride(from: promptTop, through: 0, by: -1).first(where: { barPixels($0) >= threshold })
        else { return [] }
        var top = bottom
        while top - 1 >= 0, barPixels(top - 1) >= threshold { top -= 1 }
        let row = (top + bottom) / 2

        var segments: [ProgressSegmentSG] = []
        var x = minX
        while x < maxX {
            guard let filled = kind(x, row) else { x += 1; continue }
            let start = x
            while x < maxX, kind(x, row) == filled { x += 1 }
            // Anti-aliased edges and stray pixels are not segments.
            if x - start >= 8 { segments.append(ProgressSegmentSG(width: CGFloat(x - start), filled: filled)) }
        }
        return segments
    }
}
