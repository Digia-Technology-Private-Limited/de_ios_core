import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// Component visual and hierarchy snapshot tests for `CampaignCanvasView`.
///
/// Validates:
/// 1. `.image` (Visual Goldens): Pixel appearance, colors, corner radius, borders, and layouts.
/// 2. `.hierarchy`: View hierarchy structure, frames, text content, and subview nesting.
@Suite("Canvas component tests", .serialized, .tags(.canvas, .component))
struct CanvasComponentTests {

    private func loadCanvasConfig(named name: String) throws -> InlineCanvasConfig {
        guard let fixture = FixtureLoader.loadFixture(campaignType: "canvas", fileName: name) else {
            Issue.record("Failed to load canvas fixture \(name)")
            throw CancellationError()
        }
        guard let templateConfig = fixture["templateConfig"] as? [String: Any] else {
            Issue.record("Missing templateConfig in \(name)")
            throw CancellationError()
        }
        guard let config = InlineCanvasConfig.fromJson(templateConfig) else {
            Issue.record("Failed to parse InlineCanvasConfig from \(name)")
            throw CancellationError()
        }
        return config
    }

    // MARK: - 1. Solid Background Canvas

    @Test("matches the solid background canvas visual golden", .tags(.golden, .smoke)) @MainActor
    func testCanvasSolidBackgroundVisualGolden() throws {
        let config = try loadCanvasConfig(named: "canvas-bg-solid.json")
        let hostView = ComponentTestHost.makeCanvasSlotHost(config: config)
        defer { ComponentTestHost.cleanupCanvasSlotHost(hostView, slotKey: config.slotKey) }

        assertVisualGolden(
            matching: ComponentTestHost.renderImage(of: hostView),
            precision: 0.999,
            perceptualPrecision: 0.98
        )
    }

    @Test("matches the solid background canvas view hierarchy snapshot", .tags(.golden, .smoke)) @MainActor
    func testCanvasSolidBackgroundHierarchy() throws {
        let config = try loadCanvasConfig(named: "canvas-bg-solid.json")
        let hostView = ComponentTestHost.makeCanvasSlotHost(config: config)
        defer { ComponentTestHost.cleanupCanvasSlotHost(hostView, slotKey: config.slotKey) }

        assertHierarchy(matching: hostView)
    }

    // MARK: - 2. Filled Button Canvas

    @Test("matches the filled button canvas visual golden", .tags(.golden)) @MainActor
    func testCanvasButtonFillVisualGolden() throws {
        let config = try loadCanvasConfig(named: "canvas-button-fill.json")
        let hostView = ComponentTestHost.makeCanvasSlotHost(config: config)
        defer { ComponentTestHost.cleanupCanvasSlotHost(hostView, slotKey: config.slotKey) }

        assertVisualGolden(
            matching: ComponentTestHost.renderImage(of: hostView),
            precision: 0.999,
            perceptualPrecision: 0.98
        )
    }

    @Test("matches the filled button canvas view hierarchy snapshot", .tags(.golden)) @MainActor
    func testCanvasButtonFillHierarchy() throws {
        let config = try loadCanvasConfig(named: "canvas-button-fill.json")
        let hostView = ComponentTestHost.makeCanvasSlotHost(config: config)
        defer { ComponentTestHost.cleanupCanvasSlotHost(hostView, slotKey: config.slotKey) }

        assertHierarchy(matching: hostView)
    }

    // MARK: - 3. Rich Text Spans Canvas

    @Test("matches the rich text spans canvas visual golden", .tags(.golden)) @MainActor
    func testCanvasRichTextSpansVisualGolden() throws {
        let config = try loadCanvasConfig(named: "canvas-text-rich-spans.json")
        let hostView = ComponentTestHost.makeCanvasSlotHost(config: config)
        defer { ComponentTestHost.cleanupCanvasSlotHost(hostView, slotKey: config.slotKey) }

        assertVisualGolden(
            matching: ComponentTestHost.renderImage(of: hostView),
            precision: 0.999,
            perceptualPrecision: 0.98
        )
    }

    @Test("matches the rich text spans canvas view hierarchy snapshot", .tags(.golden)) @MainActor
    func testCanvasRichTextSpansHierarchy() throws {
        let config = try loadCanvasConfig(named: "canvas-text-rich-spans.json")
        let hostView = ComponentTestHost.makeCanvasSlotHost(config: config)
        defer { ComponentTestHost.cleanupCanvasSlotHost(hostView, slotKey: config.slotKey) }

        assertHierarchy(matching: hostView)
    }
}
