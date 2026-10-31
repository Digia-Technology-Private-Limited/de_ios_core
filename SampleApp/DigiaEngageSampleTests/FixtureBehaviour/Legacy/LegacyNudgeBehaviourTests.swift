import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// Legacy (pre-canvas) nudges: a `templateConfig.layout` column tree with no `layoutMode`, parsed
/// by `NudgeParser` and drawn node by node by `NudgeNodeRenderer` inside the dialog and the bottom
/// sheet. Fixtures: `legacy_nudge/legacy_nudge_dialog` (every text, divider, progress and button
/// variant, spans, variables, box styles, an unknown and an untyped node) and
/// `legacy_nudge/legacy_nudge_bottomsheet` (every media node, placeholders, a locked backdrop).
///
/// iOS only: Flutter no longer reads this shape, so there is no Flutter test to port; the cases
/// follow `flutter/core/test/fixture_behaviour/ui_nudge_test.dart` (show, close paths, backdrop).
@Suite("Legacy nudge (column tree)", .serialized, .tags(.integration, .behaviour, .nudge))
@MainActor
struct LegacyNudgeBehaviourTests {

    private static let dialogKey = "test_legacy_nudge_dialog"
    private static let sheetKey = "test_legacy_nudge_bottomsheet"
    private static let dialogTitle = "Hi Asha, your reward is ready"
    private static let sheetTitle = "Weekend flash sale"

    private func showDialog() async throws -> (SdkHarness, CampaignPresentation) {
        let sdk = try await SdkHarness.legacyStart([fixture("legacy_nudge/legacy_nudge_dialog")])
        let presentation = try sdk.deliver(Self.dialogKey, variables: ["first_name": "Asha"])
        try await sdk.waitUntil("the legacy dialog is up") { sdk.isShowing(Self.dialogTitle) }
        return (sdk, presentation)
    }

    private func showSheet() async throws -> (SdkHarness, CampaignPresentation) {
        let sdk = try await SdkHarness.legacyStart([fixture("legacy_nudge/legacy_nudge_bottomsheet")])
        let presentation = try sdk.deliver(Self.sheetKey)
        try await sdk.waitUntil("the legacy sheet is up") { sdk.isShowing(Self.sheetTitle) }
        return (sdk, presentation)
    }

    // MARK: - Dialog

    // Fails if `NudgeParser.parseNode` stops dispatching a node type (that node's text disappears),
    // stops dropping an unknown type (`default: return nil`), or if `NudgeTextView` draws
    // `node.text` instead of the spans when `node.spans` is non-empty.
    @Test("a legacy dialog draws its column tree with spans and variables, and drops unknown nodes")
    func dialogDrawsTheColumnTree() async throws {
        let (sdk, presentation) = try await showDialog()
        defer { sdk.tearDown() }

        let nudge = try #require(sdk.sdk.controller.activeNudge)
        #expect(nudge.config.canvas == nil)
        #expect(nudge.config.surface.displayType == .dialog)
        // 14 authored children: the unknown widget and the untyped node are dropped.
        #expect(nudge.config.layout.children.count == 12)

        // The CEP variable fills the title; `stamps` falls back to its sample value.
        #expect(sdk.isShowing("Save 20% on your next order"))
        #expect(!sdk.isShowing("fallback copy that the spans replace"))
        #expect(sdk.isShowing("3 of 4 stamps collected"))
        for label in ["Copy code SAVE20", "Open rewards", "Not now", "Remind me tomorrow"] {
            #expect(sdk.legacyIsShowingExact(label), "\(label) is on screen")
        }
        #expect(!sdk.isShowing("UNKNOWN WIDGET MUST NOT RENDER"))
        #expect(!sdk.isShowing("UNTYPED NODE MUST NOT RENDER"))
        #expect(presentation.outcome.settledValue == nil)
        #expect(try await sdk.legacyTracked("Digia Experience Viewed", of: Self.dialogKey).count == 1)
    }

    // Fails if `NudgeButtonView.handleTap` stops running the button's actions, or stops reporting
    // the primary click (`if node.isPrimary { ... emitNudgeClick(elementId: "cta_primary" ...) }`).
    @Test("the primary button copies its code, reports the click, and keeps the dialog up")
    func primaryButtonCopies() async throws {
        let (sdk, presentation) = try await showDialog()
        defer { sdk.tearDown() }

        try await sdk.legacyTapExact("Copy code SAVE20")

        try await sdk.waitUntil("the code is copied") { !sdk.platform.copied.isEmpty }
        #expect(sdk.platform.copied == ["SAVE20"])
        let clicked = try await sdk.legacyOnly("Digia Experience Clicked", of: Self.dialogKey)
        #expect(clicked["element_id"] as? String == "cta_primary")
        #expect(clicked["cta_label"] as? String == "Copy code SAVE20")
        #expect(sdk.isShowing(Self.dialogTitle))
        #expect(presentation.outcome.settledValue == nil)
    }

    // Fails if the action steps stop resolving variables (`action.resolved(with: variables)` in
    // `EngageActionExecutor.executeAction`) or if `dismissNudgeFromCta` stops passing `.ctaAction`.
    @Test("a two-step button opens its deep link with the variable filled, then closes as a CTA")
    func outlineButtonDeepLinksThenDismisses() async throws {
        let (sdk, presentation) = try await showDialog()
        defer { sdk.tearDown() }

        try await sdk.legacyTapExact("Open rewards")

        try await sdk.waitUntil("the nudge closed") { presentation.outcome.settledValue != nil }
        #expect(sdk.platform.opened == ["digia-test://rewards/Asha"])
        #expect(presentation.dismissReason == .ctaAction)
        #expect(sdk.sdk.controller.activeNudge == nil)
        // A secondary button reports no click on a legacy nudge: only `isPrimary` emits one.
        let names = try await sdk.legacyEventNames(of: Self.dialogKey, once: "Digia Experience Dismissed")
        #expect(!names.contains("Digia Experience Clicked"))
        #expect(names.contains("Digia Experience Dismissed"))
    }

    // Fails if `LocalActionExecutor` stops treating `Action.dismissDialog` as the dismiss action.
    @Test("a text button authored with dismissDialog closes the dialog as a CTA")
    func textButtonDismisses() async throws {
        let (sdk, presentation) = try await showDialog()
        defer { sdk.tearDown() }

        try await sdk.legacyTapExact("Not now")

        try await sdk.waitUntil("the nudge closed") { presentation.outcome.settledValue != nil }
        #expect(presentation.dismissReason == .ctaAction)
        try await sdk.waitUntil("the dialog faded out") { !sdk.isShowing(Self.dialogTitle) }
    }

    // Fails if `EngageActionParser.unsupported` stops returning nil (an unknown step would run as
    // something), or the parse no longer reports it with `unsupportedActionType`.
    @Test("a button whose only step is unknown does nothing, and the unknown step is reported")
    func unknownActionIsANoOp() async throws {
        let (sdk, presentation) = try await showDialog()
        defer { sdk.tearDown() }

        try await sdk.legacyTapExact("Remind me tomorrow")
        try await sdk.settle(0.4)

        #expect(sdk.isShowing(Self.dialogTitle))
        #expect(presentation.outcome.settledValue == nil)
        #expect(sdk.platform.opened.isEmpty)
        #expect(!sdk.records(Self.dialogKey, reason: TimelineReason.unsupportedActionType).isEmpty)
    }

    // Fails if `NudgeDialogContainer.handleBackdropTap` ignores `backdropDismissible`, or the scrim
    // loses its `onTapGesture`.
    @Test("a tap on the scrim closes a dialog whose backdrop dismisses")
    func backdropClosesTheDialog() async throws {
        let (sdk, presentation) = try await showDialog()
        defer { sdk.tearDown() }
        try await sdk.settle(0.4)

        try sdk.legacyTapBackdrop()

        try await sdk.waitUntil("the nudge closed") { presentation.outcome.settledValue != nil }
        // iOS and Flutter both report a scrim tap on a nudge as a user close, not `scrimTap`.
        #expect(presentation.dismissReason == .userClose)
        #expect(sdk.sdk.controller.activeNudge == nil)
    }

    // Fails if `dialogPanel` stops drawing `NudgeCloseButton` when `surface.showCloseButton` is on
    // for a legacy (non-canvas) dialog.
    @Test("the close button closes the dialog as a user close")
    func closeButtonClosesTheDialog() async throws {
        let (sdk, presentation) = try await showDialog()
        defer { sdk.tearDown() }

        try await sdk.legacyTapExact("Close")

        try await sdk.waitUntil("the nudge closed") { presentation.outcome.settledValue != nil }
        #expect(presentation.dismissReason == .userClose)
    }

    // MARK: - Bottom sheet

    // Fails if `NudgeImageView` / `NudgeLottieView` / `NudgeCarouselView` stop falling back to
    // `nudgePlaceholder` for an empty source, or `NudgeParser.extractChildren` stops reading the
    // `{ "children": { "children": [...] } }` wrapper (nothing would show).
    @Test("a legacy sheet draws its media nodes, with placeholders for the empty ones")
    func sheetDrawsMedia() async throws {
        let (sdk, presentation) = try await showSheet()
        defer { sdk.tearDown() }

        let nudge = try #require(sdk.sdk.controller.activeNudge)
        #expect(nudge.config.surface.displayType == .bottomSheet)
        #expect(nudge.config.layout.children.count == 13)
        #expect(sdk.isShowing("T&C apply"))
        #expect(sdk.legacyIsShowingExact("Image"), "the empty image and carousel show a placeholder")
        #expect(sdk.legacyIsShowingExact("Lottie"), "the empty Lottie shows a placeholder")
        #expect(sdk.legacyIsShowingExact("Shop the sale"))
        #expect(presentation.outcome.settledValue == nil)
    }

    // Fails if the sheet's backdrop ignores `backdropDismissible` (`allowBackdropDismiss:` in
    // `NudgeSheetView`), or `Action.hideBottomSheet` stops being the dismiss action.
    @Test("a locked backdrop keeps the sheet up; its text button closes it")
    func lockedBackdropThenTextButton() async throws {
        let (sdk, presentation) = try await showSheet()
        defer { sdk.tearDown() }
        try await sdk.settle(0.4)

        try sdk.legacyTapBackdrop()
        try await sdk.settle(0.4)
        #expect(sdk.isShowing(Self.sheetTitle))
        #expect(presentation.outcome.settledValue == nil)

        try await sdk.legacyTapExact("Maybe later")
        try await sdk.waitUntil("the sheet closed") { presentation.outcome.settledValue != nil }
        #expect(presentation.dismissReason == .ctaAction)
    }

    // Fails if the legacy unprefixed `deep_link` / `dismiss` step names stop parsing in
    // `EngageActionParser.parseStep` (nothing opens, the sheet stays).
    @Test("the sheet's primary button runs the legacy deep_link and dismiss steps")
    func sheetPrimaryDeepLinks() async throws {
        let (sdk, presentation) = try await showSheet()
        defer { sdk.tearDown() }

        try await sdk.legacyTapExact("Shop the sale")

        try await sdk.waitUntil("the sheet closed") { presentation.outcome.settledValue != nil }
        #expect(sdk.platform.opened == ["digia-test://sale/weekend"])
        #expect(presentation.dismissReason == .ctaAction)
        let clicked = try await sdk.legacyOnly("Digia Experience Clicked", of: Self.sheetKey)
        #expect(clicked["action_url"] as? String == "digia-test://sale/weekend")
    }
}
}
