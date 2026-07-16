# Changelog

All notable changes to Digia Engage (iOS) are documented in this file.

## [3.6.0] - 2026-07-16

### New Features
- Campaigns can now be targeted to specific screens: a campaign is shown only when the app's current screen — reported through the screen-tracking API — matches the target screens configured for it. Campaigns with no screen targeting continue to show everywhere.

### Improvements
- Reworked font handling so all campaign text resolves the dashboard-specified font weight (numeric `100`–`900` or a named weight like `bold`) against the app-configured font family, for consistent weight and italic rendering across nudges, guides, surveys, and stories.

### Bug Fixes
- Guide step buttons, the guide step indicator, and survey options now honor the font size and weight configured for them in the dashboard, instead of rendering at fixed sizes.

## [3.5.0] - 2026-07-15

### New Features
- Added host action handlers: hosts can now intercept the actions authored in Digia Engage — custom key-value actions, deep links, and external URL opens — and run their own code instead of the SDK's default. Register them up front via `DigiaConfig(actionHandlers:)`, or swap them at runtime with `Digia.setCustomKVHandler(_:)`, `setDeepLinkHandler(_:)`, and `setOpenURLHandler(_:)`; passing `nil` restores the SDK default (deep links and URLs open natively, custom key-value is a no-op). This also introduces custom key-value as a new action type campaigns can trigger.

### Bug Fixes
- Fixed the configured font family not being applied to all campaign text: guide overlays, story CTA buttons, survey text, and nudge placeholder/error text previously rendered in the system font, and now use the SDK's configured font — including UIKit-rendered rich nudge title and subtitle text.

## [3.4.0] - 2026-07-15

### New Features
- The SDK can now be integrated into apps with a deployment target as low as iOS 15. SDK functionality still requires iOS 17 — on iOS 15 and 16 every entry point no-ops — so hosts that support older OS versions can link a single build without a conditional dependency. As part of this, `DigiaNetworkConfiguration.timeout` is now a `TimeInterval` in seconds instead of a `Duration`; hosts passing an explicit timeout need to update the call site.
- Added `clearInlineContent(_:)` and `clearAllInlineContent()` to clear loaded inline carousel and story content for specific placements or for all of them. Inline content was previously retained indefinitely once loaded, with no way to drop it — call these on logout so one user's content doesn't linger across an account switch.

### Improvements
- Completed story segments now use the active indicator color, and the separate completed-segment color is no longer configurable.

### Bug Fixes
- Fixed analytics events being discarded when a track request failed with a client error or came back without a usable HTTP status — those failures are now retried instead of dropping the batch.

## [3.3.0] - 2026-07-10

### New Features
- Nudge buttons can now trigger the native App Store review prompt.
- Added manual and automatic screen tracking — the current screen name is now forwarded to CEP plugins and included in relevant analytics events.
- React Native can now hand native its already-fetched campaign list instead of native re-fetching it.
- Inline carousel now supports configurable item spacing and corner radius, with peeking-neighbor scrolling.
- Images in nudges, carousels, and surveys now show a blurred placeholder while loading instead of a blank space.
- Nudge videos now show a loading spinner while buffering and a visible error state on failure; videos configured without controls render without the system player chrome.
- CEP plugins can now report whether they accepted or dropped a triggered campaign, so a plugin holding a rendering slot knows to release it on rejection.

### Improvements
- Inline carousel loop now cycles through a bounded set of slides instead of an effectively unbounded page count.
- SDK logging is now gated by the configured log level instead of always-on debug output, and unhealthy CEP plugin state is now surfaced as a warning.
- Analytics event batching defaults increased to reduce network overhead.
- Simplified survey block scroll-height sizing to a single formula.

### Bug Fixes
- Fixed the full-screen story overlay freezing and not responding to taps when hosted inside a pure SwiftUI app.
- Fixed full-screen story videos losing sync with their progress bar; a stalled video now auto-advances instead of hanging indefinitely, and full-screen images now letterbox instead of cropping.
- Fixed the story strip's swipe-to-dismiss gesture swallowing taps meant for story navigation.
- Fixed completed story segments showing the active color instead of the completed color.
- Fixed nudge images without an aspect ratio or fixed height collapsing instead of defaulting to a sensible height, and fixed cover-fit images not preserving aspect ratio while filling their frame.
- Fixed survey "upvote" blocks being incorrectly treated as multi-select.
