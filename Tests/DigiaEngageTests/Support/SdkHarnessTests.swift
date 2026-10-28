import SwiftUI
import Testing

@testable import DigiaEngage

extension RenderedUITests {
    /// The harness itself, in the package's test bundle, which has no app scene: `mount` falls back
    /// to a free-standing window, and a trigger that arrives before READY waits in `FakeCep`.
    @Suite("SdkHarness", .serialized)
    @MainActor
    struct SdkHarnessTests {

        @Test("a delivered inline campaign shows in a slot mounted without an app scene")
        func mountsWithoutAScene() async throws {
            let sdk = try await SdkHarness.start(textCard("harness_card", text: "Harness card"))
            defer { sdk.tearDown() }
            try sdk.mount { DigiaSlot("harness_slot") { EmptyView() } }

            let presentation = try sdk.deliver("harness_card")

            try await sdk.waitUntil("the card shows") { sdk.isShowing("Harness card") }
            #expect(sdk.outcome(of: presentation) == nil)
        }

        @Test("a trigger received before READY is buffered, then delivered when the bundle arrives")
        func heldTriggerIsFlushedOnReady() async throws {
            let sdk = try await SdkHarness.startHeld(textCard("harness_card", text: "Harness card"))
            defer { sdk.tearDown() }
            try sdk.mount { DigiaSlot("harness_slot") { EmptyView() } }

            #expect(sdk.cep.receive("harness_card") == nil)
            #expect(sdk.cep.buffered == 1)

            try await sdk.releaseBundle()

            #expect(sdk.cep.presentations.map(\.campaignKey) == ["harness_card"])
            try await sdk.waitUntil("the card shows") { sdk.isShowing("Harness card") }
        }
    }
}

private func textCard(_ key: String, text: String) -> [String: Any] {
    [
        "id": "\(key)-id",
        "campaignKey": key,
        "campaignType": "inline",
        "templateConfig": [
            "templateType": "canvas",
            "slotKey": "harness_slot",
            "designWidth": 360,
            "canvas": [
                "version": 2,
                "canvasWidth": 360,
                "canvasHeight": 120,
                "children": [[
                    "kind": "widget",
                    "id": "harness_text",
                    "rect": ["x": 0.1, "y": 0.1, "width": 0.8, "height": 0.8],
                    "widget": [
                        "type": "digia/text",
                        "props": ["spans": [["text": text]]],
                    ] as [String: Any],
                ] as [String: Any]],
            ] as [String: Any],
        ] as [String: Any],
    ]
}
