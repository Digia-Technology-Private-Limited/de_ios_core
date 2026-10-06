import Testing

/// Test tags. Put them on a `@Suite` (or a single `@Test`) with `.tags(...)`; `./run-tests.sh <tag>`
/// selects by tag through `xcodebuild -only-testing-tags`. Tag every suite with one *kind* and one
/// or more *areas*.
///
/// Swift Testing only: XCTestCase classes (e.g. `SessionIdentity/`) cannot carry tags.
extension Tag {

    // MARK: - Kind: what the test proves (pick one)

    /// Pure logic with no rendering and no I/O: algorithms, state machines, math, boundaries.
    @Tag static var unit: Self
    /// Wire/model contract: parsing, serialization, enum wire strings, public API shape.
    @Tag static var contract: Self
    /// A SwiftUI/UIKit view hosted in a test host, asserted by structure or geometry (no pixels).
    @Tag static var component: Self
    /// Pixel golden: rendered image diffed against a recorded reference.
    @Tag static var golden: Self
    /// Several real collaborators wired together (SDK init, network + storage, CEP delivery).
    @Tag static var integration: Self

    // MARK: - Gate: when it runs (optional)

    /// Small, fast, critical subset that must pass on every change.
    @Tag static var smoke: Self
    /// Noticeably slow (run-loop waits, timers, large fixtures); excluded from quick runs.
    @Tag static var slow: Self

    // MARK: - Area: which feature it covers (one or more)

    /// Nudge surfaces: dialog, bottom sheet, full screen, close button, nudge video.
    @Tag static var nudge: Self
    /// Inline surfaces: banner, carousel, canvas, story.
    @Tag static var inline: Self
    /// Campaign canvas: layout, strips, text, survey configuration.
    @Tag static var canvas: Self
    /// Surface rules: routing, supersede, priority, presentation controller/coordinator.
    @Tag static var surface: Self
    /// Frequency capping and eligibility.
    @Tag static var frequency: Self
    /// Session and identity: session lifecycle, user/device id, rotation, resume, reporting.
    @Tag static var session: Self
    /// Analytics events, health sink, delivery timeline, timeline wire strings.
    @Tag static var analytics: Self
    /// CEP v2 interface: trigger payloads, host delivery, wire enums.
    @Tag static var cep: Self
    /// Network client, request headers, mock transport.
    @Tag static var network: Self
    /// Local/scoped storage and storage migration.
    @Tag static var storage: Self
    /// SDK lifecycle: `Digia.initialize`, services, configuration.
    @Tag static var sdk: Self
    /// Action execution: CTA actions, deep links, local actions.
    @Tag static var actions: Self
    /// Variable interpolation and templating.
    @Tag static var interpolation: Self
    /// Component registry and anchors.
    @Tag static var registry: Self
    /// Media: video streaming, aspect ratio/fit, images, fonts, color.
    @Tag static var media: Self
    /// Debug tooling: logger, debug overlay, debug deep link, test kit, live-test reliability.
    @Tag static var debug: Self
}
