import Testing

/// Parent of every suite that renders through a key window, `ComponentTestHost` or the SDK's
/// shared controllers, golden and hierarchy snapshots included.
///
/// Those suites share one key window and the process-wide SDK singletons, so two of them running
/// at once spoil each other's frames and state. `.serialized` on a suite only orders its own
/// tests; on this parent it applies to every suite nested in it, so they run one at a time even
/// under `./run-tests.sh all`. Nest a new rendering suite with `extension RenderedUITests { … }`.
@Suite(.serialized)
struct RenderedUITests {}
