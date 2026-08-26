# Changelog

All notable changes to Digia Engage (iOS) are documented in this file.

## [3.12.0] - 2026-08-26

### New Features
- Added story floater campaigns: a small floating canvas window — draggable, edge-snapping, and dismissible — that opens a full-screen story when tapped, animating between the collapsed window and the expanded story, with safe-area handling.
- Canvas-designed content can now render inline in a placement slot — a free-form canvas, a canvas carousel, or a canvas story (with progress bars and tap-to-advance, close, and mute controls) — drawn by the shared canvas renderer alongside the existing inline banner, carousel, and story types.

### Improvements
- The SDK now sends a version descriptor to Digia when fetching campaigns, so the backend can serve content the installed SDK supports, and exposes the SDK version through the new `Digia.sdkVersion` property.

## [3.11.0] - 2026-08-20

### New Features
- Added anchorless Canvas spotlight guides that target captured screen regions without host-registered anchor keys, and live testing.
- React Native debug builds can now capture the current page and selected UI structure from the Digia debug settings and upload it for dashboard guide authoring; text, media, and other structural nodes are opt-in.

### Bug Fixes
- Fixed Canvas text using fit-to-text sizing measuring wider than its content, so text now keeps its authored width and alignment.
- Fixed Canvas text ignoring its authored horizontal alignment; left-, center-, and right-aligned text now render as configured.

## [3.10.1] - 2026-08-19

### Improvements
- Live campaign testing now supports floater (Picture-in-Picture) and guide campaigns, in addition to nudge, survey, and inline.

### Bug Fixes
- Fixed canvas bottom-sheet nudges (which use a transparent background) letting taps fall through to the backdrop instead of keeping the sheet interactive; drag-to-dismiss and content taps now work as expected.
- Fixed Picture-in-Picture controls rendering behind the media in the collapsed window for some media types; the controls now stay above every media kind.
- Fixed a Lottie element's shadow in canvas designs extending beyond its box; the shadow is now constrained to the element's shape.

## [3.10.0] - 2026-08-19

### New Features
- Campaigns designed in the dashboard's canvas editor now render natively: a new design-token-based renderer draws canvas layouts — containers, decorations, shadows, borders, and rich text — with light/dark theming, for both dialog and bottom-sheet nudges.
- Added Picture-in-Picture campaigns: a small draggable floating window that expands to full screen and plays media (video, image, or Lottie), with playback controls, mute, edge-snapping, and automatic pause/resume as the app backgrounds and foregrounds. Hosts can read the floating window's on-screen frame via `Digia.floaterActiveRect` to route taps on it correctly.
- Added a theme mode setting — `DigiaConfig(themeMode:)` and `Digia.setThemeMode(_:)`, one of auto, light, or dark — that controls how design-token (canvas) content resolves its light and dark colors.

### Improvements
- The debug-only live campaign testing now lets you set a custom device name, shown when you connect a device for a live session.
- The React Native bridging method `Digia.populateCampaigns(_:)` has been renamed to `Digia.populateCampaignBundle(_:)` and now takes the full campaign-bundle response (which includes canvas designs) instead of the earlier campaigns list.

### Bug Fixes
- A nudge or survey bottom sheet now honors its backdrop-tap-to-dismiss and drag-to-dismiss settings independently; previously, enabling either one enabled both.
- Fixed text glyphs not covered by the configured font — for example an arrow appended to a button label — rendering at the wrong weight; a substituted glyph now matches the label's weight.

## [3.9.0] - 2026-08-03

### New Features
- Nudge Lottie widgets now support dotLottie (`.lottie`) animation files in addition to JSON Lottie files.
- Dialog nudges can now present full-screen and can be constrained to the device safe area through a new option; dialog content taller than the available height now scrolls instead of being clipped.

### Bug Fixes
- Fixed inline story thumbnail video previews playing for the wrong cards and not tracking the visible area correctly; thumbnails now play based on their actual on-screen position and show the correct poster frame.

## [3.8.0] - 2026-08-01

### New Features
- Added the Engage Component Registry: a debug-build tool that records the Engage component keys and slots your app renders so they surface in the dashboard. It's reached through a new in-app debug settings screen — opened from your own debug menu via `Digia.presentDebugSettings(from:)`, or by routing the SDK's `_digia/debug-settings` deep link through `Digia.handleDeepLink(_:from:)` — and surfaced by a draggable on-screen debug bubble. It activates only in development builds and is inert in release builds.
- Added live campaign testing: in a development build, use the debug bubble's Sync toggle to connect to the dashboard and preview nudge and survey campaigns live as you edit them.
- Inline story strips now autoplay muted video previews in their thumbnails: a story card backed by a video plays in place while it's on screen and stops when it scrolls away, instead of showing a static poster frame.

### Bug Fixes
- Fixed a bottom-sheet nudge showing the previous nudge's content, and not recording an impression, when one nudge replaced another in quick succession.

## [3.7.0] - 2026-07-29

### New Features
- Added an inline banner campaign type: a tappable image banner that renders in a placement slot, with configurable image fit (cover, contain, or fill), aspect ratio, height, corner radius, margins, a loading placeholder, and a tap action (open URL, deep link, share, copy, or custom key-value).
- Added a linear progress bar nudge widget: a determinate horizontal bar that shows either a percentage or a start/current/end range (e.g. "700 of 1000"), with configurable indicator and track colors, thickness, and corner radius.
- Full-screen story overlays can now show configurable close and video-mute controls — including visibility, icon color, background color, and size. Stories can start videos muted or audible, and once the viewer changes the audio state that choice persists for the rest of the story session.
- Inline carousels, inline and full-screen story media, and nudge videos now support configurable content fit (cover/contain, plus fill for images) and aspect ratio, so media is sized to match the design instead of a fixed default.
- The nudge close button's icon color and size are now configurable from the dashboard.

### Improvements
- Screen-targeted campaigns are now dismissed when the app navigates to a screen outside their target set, not only prevented from showing when triggered — so a campaign tied to one screen no longer lingers after the user moves to another.

## [3.6.1] - 2026-07-18

### Bug Fixes
- Fixed the guide step indicator and body text default colors rendering at the wrong opacity, caused by the built-in default color values using the wrong hex byte order.
- Fixed inline story strips containing multiple videos exhausting the device's media pipeline: video players are now created only for on-screen cards and fully released when a card scrolls away or the story closes, so videos play reliably instead of failing once several are present.

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
