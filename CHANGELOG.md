# Changelog

All notable changes to Digia Engage (iOS) are documented in this file.

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
