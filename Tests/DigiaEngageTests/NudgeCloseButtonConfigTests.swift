import SwiftUI
import Testing
@testable import DigiaEngage

struct NudgeCloseButtonConfigTests {
    private func config(container: [String: Any] = [:], spacing: Any = 24) throws -> NudgeConfig {
        try #require(NudgeConfig.fromJson([
            "container": container,
            "layout": [
                "type": "digia/column",
                "props": ["spacing": spacing],
                "children": [],
            ],
        ]))
    }

    @Test("missing close button config preserves the existing appearance")
    func defaults() throws {
        let surface = try config().surface
        let close = surface.closeButton
        #expect(close == .defaults)
        #expect(close.diameter == 26)
        #expect(surface.bottomSafeAreaMode == .insetContent)
    }

    @Test("bottom safe-area mode accepts known values and safely defaults unknown values")
    func bottomSafeAreaMode() throws {
        #expect(try config(container: ["bottomSafeAreaMode": "insetSurface"]).surface.bottomSafeAreaMode == .insetSurface)
        #expect(try config(container: ["bottomSafeAreaMode": "none"]).surface.bottomSafeAreaMode == .none)
        #expect(try config(container: ["bottomSafeAreaMode": "invalid"]).surface.bottomSafeAreaMode == .insetContent)
    }

    @Test("custom close button config clamps negatives and accepts zero")
    func customValues() throws {
        let close = try config(container: [
            "closeButton": [
                "marginTop": -8,
                "marginRight": 0,
                "backgroundColor": "#80112233",
                "iconColor": "#AABBCC",
                "iconSize": 0,
            ]
        ]).surface.closeButton

        #expect(close.marginTop == 0)
        #expect(close.marginRight == 0)
        #expect(close.iconSize == 0)
        #expect(close.diameter == 10)
        #expect(close.backgroundColor == Color(hex: "#80112233"))
        #expect(close.iconColor == Color(hex: "#AABBCC"))
    }

    @Test("malformed close button config falls back safely")
    func malformedValues() throws {
        let close = try config(container: [
            "closeButton": [
                "marginTop": "invalid",
                "backgroundColor": "transparent",
                "iconColor": "#GGGGGG",
                "iconSize": "invalid",
            ]
        ]).surface.closeButton

        #expect(close == .defaults)
    }

    @Test("legacy column spacing is ignored")
    func ignoresSpacing() throws {
        let legacy = try config(spacing: 42)
        let zeroSpacing = try config(spacing: 0)
        #expect(legacy.layout == zeroSpacing.layout)
    }
}
