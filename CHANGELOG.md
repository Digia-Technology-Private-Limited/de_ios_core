# Changelog

All notable changes to Digia Engage (iOS) are documented in this file.

## [3.14.0] - 2026-09-10

### New Features
- **Canvas survey campaigns** — introduced multi-step surveys authored in Campaign
  Canvas (`layoutMode: 'canvas'`), featuring freeform canvas scene layouts, animated
  scene transitions (slide and fade), styled managed host widgets (progress bar,
  step indicator, navigation buttons, auto-advance timers), and dynamic conditional
  branching based on answer values. Supports single- and multi-choice cards (grid
  and column layouts), numeric NPS scales, 5-star rating bars with custom star
  geometries, emoji reaction scales with bundled reaction assets, single/multi-line
  text fields, and date picker inputs with configurable date formats, backed by
  per-field validation rules and styled error labels.
- **Stateful inline canvas timers** — introduced stateful countdown timers rendered
  via Campaign Canvas inside `DigiaSlot` (`stateful` payload block with
  `kind: "timer"`). Supports four lifecycle states (`teaser`, `running`, `urgent`,
  and `ended`), each with independent Canvas designs, corner radii, and slot
  margins. Includes a dedicated `digia/timer` canvas widget supporting rich text
  countdown formatting, independently styled unit boxes (days, hours, minutes,
  seconds), auto-hiding units, overflow-safe unit decorations, foreground-aware
  timer ticks, and server time clock synchronization to prevent device clock
  skew.

### Improvements
- **SVG vector and animated GIF support** — integrated SDWebImageSVGCoder and
  WebImage across surveys, guides, nudges, carousels, and floater media surfaces,
  with eager image pipeline configuration to ensure consistent vector and
  animated GIF decoding across all visual surfaces.
- **Distance-based bottom sheet drag dismissal** — implemented a unified
  distance-only drag dismissal policy across survey and nudge bottom sheets,
  requiring an explicit downward drag to dismiss, smoothly snapping back when
  released below the threshold, and animating sheet height smoothly between
  survey steps of varying heights.
- **Survey presentation chrome and dialog routing** — canvas surveys can present as
  modal bottom sheets (with drag handles and optional backdrop dismissal) or
  centered dialogs with customizable backdrop styling and dismissibility. Includes a
  vector close button overlay matching dashboard Lucide X specifications and
  maintaining authored edge margins across differing scene dimensions.
- **Enriched timer event telemetry** — inline timer impressions, clicks, and
  dismissals now attach structured timer context to Digia analytics and CEP forward
  events, capturing the active state rule ID, remaining time bucket (`<5m`, `15-5m`,
  `60-15m`, `6-1h`, `24-6h`, `>24h`, or `expired`), deadline source (`fixed` vs.
  `fromVariable`), CTA role (`primary` or `secondary`), and resolved destination
  URL.
- **SDK resource bundle packaging** — added resource bundle declarations to Swift
  Package Manager and CocoaPods podspecs to bundle reaction assets directly with
  the SDK, with support in universal xcframework build packaging.

### Bug Fixes
- **Session and identity concurrency stabilization** — synchronized user identity
  operations across the SDK, serializing `setUserId` and `clearUserId` while
  skipping no-op identity changes when the user ID is unchanged. Event timestamps
  and session expiration checks are now evaluated before timestamp capture, and
  analytics teardown cancels pending async tasks safely.
- **Primary canvas tap region conversion reporting** — transparent and styled
  canvas tap regions flagged as `isPrimary` now report qualifying primary CTA
  conversion clicks (`ExperienceClicked`) to connected CEP platforms and Digia
  analytics even when authored without navigation or hide actions.
- **Inline canvas slot lifecycle and cache clearing** — inline Canvas and timer
  slots now track owned lifecycle state, properly clear state when their payload
  is removed to prevent stale displays or duplicate dismissals, and re-arm
  impressions and redraws on slot content update.
- **Flexible timer timestamp parsing** — inline timers now parse JavaScript
  `Date.toString()` strings, epoch seconds and milliseconds (including CleverTap
  `$D_` prefixes), and ISO-8601 timestamps, defaulting to UTC when timezone
  offsets are omitted.
- **Survey completion analytics attribution** — completing a canvas survey now
  suppresses the `abandonedAtItem` property in `SurveyDismissed` telemetry, and
  advancing past the survey welcome scene properly records the survey start event.
- **Rating star geometry and bounding box** — corrected 5-star rating SVG path
  definitions and layout constraints to match dashboard canvas preview dimensions,
  preventing visual clipping and misalignment across custom rating symbols.

## [3.13.2] - 2026-09-08

### Bug Fixes
- A floating-window campaign that is dismissed before its media ever appears (an abandoned load) now releases its CEP rendering slot instead of holding it, so a later queued campaign can still be shown.
- Opening a story from a floating window now opens at the authored page (or the tapped item) instead of always starting at the first page.
- Inline placements now report their CEP impression when the slot first renders and their CEP dismissal when the content is finally removed, instead of reporting both the moment the campaign is delivered — so CEP analytics reflect what was actually shown.
- Completing a guide no longer sends an unintended click event to CEP plugins.
- A dismiss action on an inline canvas no longer runs its dismissal twice.

## [3.13.1] - 2026-09-02

### Bug Fixes
- Anchored guides now tolerate a brief detachment or remount of their target view — such as when the host rebuilds or recycles the anchored view — waiting for the anchor to reappear instead of dismissing the guide step immediately.
- The guide spotlight overlay now honors an alpha value embedded in its configured color, instead of always dimming at the default opacity.

## [3.13.0] - 2026-09-01

### New Features
- Anchored guides now render natively on iOS. A guide step can attach to a host UI element registered through the anchor API; the SDK draws the spotlight and callout natively and keeps them locked to the anchor as the screen scrolls or relayouts, scrolls the anchor into view when it is off screen, chooses the best callout side for the available space, and hides the step gracefully when its anchor cannot be shown.
- Canvas-designed nudges can now present full screen, covering the whole surface with safe-area handling.
- Canvas nudges support a selectable close-button placement — inside or outside the surface, positioned by corner and edge with a configurable offset and gap, and with configurable icon and background color.
- Canvas nudges can now auto-dismiss after a configurable delay.
- Added `Digia.requestHeaders`, exposing the identifying metadata headers the SDK sends with its network requests, so a host can attach the same headers to its own Digia-related requests.

### Bug Fixes
- Canvas text now renders correctly: button labels stay centered and fully visible instead of being clipped, mis-aligned, or wrongly constrained, and text glyphs are no longer clipped at their edges.
- Guide dismissal and completion events now carry the guide's campaign payload to CEP plugins instead of empty metadata.

## [3.12.2] - 2026-09-01

### Improvements
- The debug tools (debug settings screen, Component Registry, live campaign testing, and on-screen debug bubble) now activate on TestFlight builds, in addition to development-provisioned builds. App Store builds remain unaffected.

### Bug Fixes
- Bottom sheets now respect the on-screen keyboard, so a keyboard no longer covers an input field inside a nudge or survey bottom sheet.
- Anchorless spotlight guides now honor their configured tap-outside behavior — advancing to the next step or doing nothing — instead of falling back to the anchored-guide dismiss-on-tap behavior.

## [3.12.1] - 2026-08-27

### Bug Fixes
- Fixed several canvas story video playback issues: each frame now keeps its poster image until the video is ready and waits for playback to actually begin before advancing (so a frame no longer flashes blank or skips ahead), a frame whose video can't load degrades gracefully instead of stalling the story, and inline and floating canvas stories now share one video playback pipeline for consistent behavior.
- Fixed canvas story videos ignoring the "fill" content-fit setting and cover-cropping instead; "fill" videos now fill the frame.
- Fixed full-screen canvas stories opened from a floating window not respecting the device safe area; their content now insets correctly.

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
