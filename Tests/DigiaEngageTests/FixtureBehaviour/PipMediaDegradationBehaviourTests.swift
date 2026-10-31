import SwiftUI
import Testing
@testable import DigiaEngage

extension RenderedUITests {
/// A picture-in-picture whose media cannot be had is never shown: no empty frame is floated for
/// it, and no impression is counted. Fixtures: `degrade_pip_variable_only_url` (the url is only the
/// variable `{{ image }}`), `degrade_pip_media_404` (a Test Kit file that does not exist); each has
/// a control that shows once its media exists.
///
/// Flutter also records every URL its image loader is asked for, to prove an unusable url is never
/// fetched and a missing one was. iOS preloads through `URLSession.shared`, which has no seam; the
/// `invalid_url` cause on the `media_load_failed` record, and the orchestrator's
/// `lastStartFailureReason`, say which path dropped it. The Test Kit media are file URLs here, so
/// "404" is a missing file: a load failure with no HTTP status, which (as a network-class fault)
/// is not reported to health.
///
/// Never shown, the showing settles as a drop, not a dismissal: Flutter's "nothing is reported"
/// (no dismissal) holds.
///
/// Port of `flutter/core/test/fixture_behaviour/surface_pip_test.dart` (group "media that cannot
/// be shown") and `flutter/core/test/fixture_behaviour/degradation_pip_test.dart`.
@Suite("PiP media degradation behaviour", .serialized,
       .tags(.integration, .behaviour, .pip, .floater, .media),
       .enabled(if: testkitAvailable, testkitSkipReason))
@MainActor
struct PipMediaDegradationBehaviourTests {

    private static let variableOnly = "degradation/degrade_pip_variable_only_url"
    private static let missing = "degradation/degrade_pip_media_404"

    /// The variable-only fixture with its `image` variable declared, which the dashboard does for
    /// a variable the author uses; the fixture as shipped leaves it undeclared.
    private func declaringImage() throws -> [String: Any] {
        try floaterFixture(Self.variableOnly, setting: [(["variables"], [["name": "image", "type": "string"]])])
    }

    /// Boots [json], delivers it and lets its media load (or fail) to the end.
    private func deliver(
        _ json: [String: Any], variables: [String: String]? = nil
    ) async throws -> (SdkHarness, CampaignPresentation) {
        let sdk = try await SdkHarness.start(json)
        do {
            let presentation = try sdk.deliverFloater(keyOf(json), variables: variables)
            // The preload is a local file read: settled well inside this, or the orchestrator's own
            // 10 s media timeout would be the only thing ending it.
            try await sdk.waitUntil("the media settles", timeout: 5) {
                sdk.pip.state == nil || (!sdk.pip.awaitingMedia && sdk.pip.activeRect != nil)
            }
            try await sdk.settle(0.3)
            return (sdk, presentation)
        } catch {
            sdk.tearDown()
            throw error
        }
    }

    /// Whether the window was ever counted as seen.
    private func impressions(_ sdk: SdkHarness, _ json: [String: Any]) async throws -> Int {
        try await sdk.eventNames(of: keyOf(json)).filter { $0 == "Digia Experience Viewed" }.count
    }

    // Fails if: Sources/DigiaEngage/api/internal/campaign/floater_orchestrator.swift `prepareMedia`
    // `if url.isEmpty || url.contains("{{") {` -> `if url.contains("{{") {` (the undeclared variable
    // resolves to ""; the empty url then reaches the loader and fails as something else).
    @Test("a url that is only an undeclared variable is never shown, and is reported as an invalid url rather than fetched")
    func undeclaredVariableUrlIsNeverShown() async throws {
        let json = try fixture(Self.variableOnly)
        let (sdk, presentation) = try await deliver(json, variables: ["image": floaterTestkitAsset("strawberry.jpg")])
        defer { sdk.tearDown() }

        #expect(sdk.pip.state == nil)
        #expect(sdk.pip.activeRect == nil, "no window was drawn")
        #expect(presentation.dropReason != nil && presentation.dismissReason == nil)
        #expect(sdk.pip.lastStartFailureReason?.contains("no usable media url") == true)
        let failure = try #require(sdk.records(keyOf(json), reason: TimelineReason.mediaLoadFailed).first)
        #expect(failure.extras["cause"] == "invalid_url")
        #expect(try await impressions(sdk, json) == 0)
    }

    // Fails if: floater_orchestrator.swift `prepareMedia` `if url.isEmpty || url.contains("{{") {` ->
    // `if url.contains("{{") {`.
    @Test("a declared variable the trigger does not supply is never shown")
    func unsuppliedDeclaredVariableIsNeverShown() async throws {
        let json = try declaringImage()
        let (sdk, presentation) = try await deliver(json)
        defer { sdk.tearDown() }

        #expect(sdk.pip.state == nil)
        #expect(sdk.pip.activeRect == nil)
        #expect(presentation.dropReason != nil && presentation.dismissReason == nil)
        #expect(sdk.pip.lastStartFailureReason?.contains("no usable media url") == true)
        let failure = try #require(sdk.records(keyOf(json), reason: TimelineReason.mediaLoadFailed).first)
        #expect(failure.extras["cause"] == "invalid_url")
        #expect(try await impressions(sdk, json) == 0)
    }

    /// The control for the two above: the same campaign shows once its url is real.
    // Fails if: floater_orchestrator.swift `preloadImage` `self.markVisible(token: token)` is deleted
    // (the media never becomes visible).
    @Test("the same campaign is shown once the trigger supplies the url")
    func suppliedVariableShows() async throws {
        let json = try declaringImage()
        let (sdk, _) = try await deliver(json, variables: ["image": floaterTestkitAsset("strawberry.jpg")])
        defer { sdk.tearDown() }

        #expect(sdk.pip.isShowing && !sdk.pip.awaitingMedia)
        #expect(sdk.pip.activeRect != nil)
    }

    // Fails if: floater_orchestrator.swift `preloadImage`'s failure branch
    // `self.abandonMedia(token: token, reason: "image failed to load", ...)` is deleted (the
    // window then waits out the 10 s media timeout instead of being dropped at once).
    @Test("an image that does not exist drops the campaign silently")
    func missingImageIsNeverShown() async throws {
        let json = try fixture(Self.missing)
        let (sdk, presentation) = try await deliver(json)
        defer { sdk.tearDown() }

        #expect(sdk.pip.state == nil)
        #expect(sdk.pip.activeRect == nil, "no empty frame was floated")
        #expect(sdk.pip.lastStartFailureReason?.contains("image failed to load") == true,
                "it must really have tried the image and been refused")
        #expect(presentation.dismissReason == nil)
        #expect(try await impressions(sdk, json) == 0)
    }

    @Test("the same campaign shows when its image exists (the control)")
    func existingImageShows() async throws {
        var json = try fixture(Self.missing)
        var template = try #require(json["templateConfig"] as? [String: Any])
        var media = try #require(template["media"] as? [String: Any])
        media["url"] = (media["url"] as? String)?.replacingOccurrences(of: "does-not-exist.png", with: "strawberry.jpg")
        template["media"] = media
        json["templateConfig"] = template
        let (sdk, _) = try await deliver(json)
        defer { sdk.tearDown() }

        #expect(sdk.pip.isShowing && !sdk.pip.awaitingMedia)
        #expect(try await impressions(sdk, json) == 1)
    }
}
}
