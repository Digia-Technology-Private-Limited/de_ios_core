// tags: golden canvas
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

/// Canvas text under a host environment other than the reference phone (TXT-T11, T06, E02, E04, E05).
///
/// Canvas text is laid out from the campaign alone: the host's Dynamic Type size and its inherited SwiftUI text
/// style must not reach it, so those variants are compared with the reference baselines in `goldens/ios/canvas/`
/// and are never recorded over them. A narrower or wider host, or dark mode, legitimately changes the frame, so
/// those variants have their own baselines in `goldens/ios/canvas_text_env/<fixture>__<variant>.png`.
///
/// Regenerate the variant baselines after an intentional visual change:
///   RECORD_SNAPSHOTS=true ./run-sample-tests.sh canvas
@MainActor
@Suite("canvas text environment goldens", .serialized, .enabled(if: WorkspaceFixtures.skipReason == nil, "Test Kit missing"))
struct CanvasTextEnvironmentGoldenTests {
    private static let unreachableForeignMedia = StubBackend.Options(foreignImagesAsStandIn: false)

    private static let referenceTextFixtures = [
        "canvas/canvas_text_paragraph_alignment.json",
        "canvas/canvas_text_line_metrics.json",
    ]

    /// Shows the campaign at [path] over [host] in a window of [size] (the full screen when `nil`) with the
    /// window's [style] and [contentSize], and compares the settled frame with `<surface>/<name>.png`.
    private func expectGolden<Host: View>(
        _ path: String,
        surface: String,
        name: String,
        recordable: Bool,
        size: CGSize? = nil,
        style: UIUserInterfaceStyle = .unspecified,
        contentSize: UIContentSizeCategory? = nil,
        @ViewBuilder host: (WorkspaceFixtures.Campaign) -> Host
    ) async throws {
        let fixture = WorkspaceFixtures.campaign("campaigns/\(path)")
        let sdk = try await SdkHarness.start([fixture], backend: Self.unreachableForeignMedia) { host(fixture) }
        defer { sdk.tearDown() }
        let window = try #require(sdk.window)
        if let size { window.frame = CGRect(origin: .zero, size: size) }
        window.overrideUserInterfaceStyle = style
        if let contentSize {
            if #available(iOS 17, *) { window.traitOverrides.preferredContentSizeCategory = contentSize }
            else { Issue.record("a content size override needs iOS 17") }
        }
        window.layoutIfNeeded()

        if let screen = fixture.targetScreens.first { Digia.setCurrentScreen(name: screen) }
        let presentation = sdk.cep.deliver(fixture.campaignKey)
        try await sdk.settle(1.5)
        #expect(presentation?.outcome.settledValue == nil, "the campaign was turned away")
        GoldenHarness.expect(window, surface: surface, name: name, recordable: recordable)
    }

    /// TXT-T11: the largest accessibility text size on the host leaves Canvas text exactly as authored.
    @Test("text_scale_2", arguments: referenceTextFixtures)
    func largeDynamicType(_ path: String) async throws {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        try await expectGolden(path, surface: "canvas", name: name, recordable: false,
                               contentSize: .accessibilityExtraExtraExtraLarge) { fixture in
            GoldenHarness.SlotHost(slotKey: fixture.slotKey ?? "home_banner")
                .dynamicTypeSize(.accessibility5)
        }
    }

    /// TXT-T06: a host that sets its own text style around the slot does not restyle Canvas text.
    @Test("hostile_theme", arguments: referenceTextFixtures)
    func hostileTextEnvironment(_ path: String) async throws {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        try await expectGolden(path, surface: "canvas", name: name, recordable: false) { fixture in
            GoldenHarness.SlotHost(slotKey: fixture.slotKey ?? "home_banner")
                .font(.system(size: 30))
                .lineSpacing(20)
                .tracking(4)
                .kerning(4)
                .multilineTextAlignment(.trailing)
        }
    }

    /// TXT-E02: a 320 x 844 pt host window scales the whole stage; the wraps stay as authored.
    @Test("narrow")
    func narrowHost() async throws {
        try await expectGolden("canvas/canvas_text_paragraph_alignment.json", surface: "canvas_text_env",
                               name: "canvas_text_paragraph_alignment__narrow", recordable: true,
                               size: CGSize(width: 320, height: 844)) { fixture in
            GoldenHarness.SlotHost(slotKey: fixture.slotKey ?? "home_banner")
        }
    }

    /// TXT-E05: dark mode changes the token colours; metrics and wraps stay as in the light baseline.
    @Test("dark")
    func darkAppearance() async throws {
        try await expectGolden("canvas/canvas_text_font_faces.json", surface: "canvas_text_env",
                               name: "canvas_text_font_faces__dark", recordable: true, style: .dark) { fixture in
            GoldenHarness.SlotHost(slotKey: fixture.slotKey ?? "home_banner")
        }
    }

    /// TXT-E04: a 1024 x 1366 pt host shows the dialog at its capped floating scale with the same wraps.
    @Test("tablet")
    func tabletHost() async throws {
        try await expectGolden("nudge_dialog/nudge_dialog_text_emergency_fit.json", surface: "canvas_text_env",
                               name: "nudge_dialog_text_emergency_fit__tablet", recordable: true,
                               size: CGSize(width: 1024, height: 1366)) { _ in
            GoldenHarness.StripedHost()
        }
    }
}
