# DigiaEngage iOS

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDigia-Technology-Private-Limited%2Fdigia_expr_swift%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Digia-Technology-Private-Limited/digia_engage_ios)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDigia-Technology-Private-Limited%2Fdigia_expr_swift%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Digia-Technology-Private-Limited/digia_engage_ios)
[![License: BSL 1.1](https://img.shields.io/badge/License-BSL%201.1-blue.svg)](LICENSE)

Digia Engage is an iOS SDK for rendering server-driven, Digia-managed experiences inside host applications. It provides dynamic page rendering, slots, overlays, dialogs, toasts, action execution, and cached image loading for SwiftUI-based integrations.

## Requirements

|       | Minimum |
| ----- | ------- |
| iOS   | 15.0    |
| Swift | 6.0     |
| Xcode | 16.0    |

The SDK builds and links against a deployment target as low as iOS 15.0, but its functionality is active only on iOS 17.0 and above — on iOS 15 and 16 every entry point safely no-ops. Deploy to iOS 17.0+ if you need Digia Engage to render.

## Installation

### Swift Package Manager

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/Digia-Technology-Private-Limited/digia_engage_ios.git",
        from: "3.6.0"
    ),
]
```

Then add `DigiaEngage` as a target dependency:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "DigiaEngage", package: "digia_engage_ios"),
    ]
)
```

Or add it directly in Xcode via **File → Add Package Dependencies** and enter the repository URL.

### CocoaPods

DigiaEngage is not published to the CocoaPods trunk. To use it with CocoaPods, point your `Podfile` at a local checkout:

```ruby
pod 'DigiaEngage', '~> 3.6.0'
```

Then run:

```bash
pod install
```

## Usage

### Initialize the SDK

```swift
import DigiaEngage

try await Digia.initialize(
    DigiaConfig(apiKey: "YOUR_API_KEY")
)
```

### Use the local Test Kit

Keep arbitrary hosts out of production configuration. A debug/noop harness can install a mock
server root before normal initialization; the root excludes `/api/v1`.

```swift
try DigiaTestKit.overrideBaseUrl("http://localhost:9871")
try await Digia.initialize(DigiaConfig(apiKey: "local-testkit"))
```

The value must be an HTTP(S) origin with no path, credentials, query, or fragment, and it
cannot change after initialization. A dedicated release-mode test build can pass
`allowInRelease: true`; ordinary production-distributed builds reject the override.

### Handle host actions

Register only the actions your app owns. When a handler is present, Digia Engage does not run its
default behavior for that action.

```swift
try await Digia.initialize(
    DigiaConfig(
        apiKey: "YOUR_API_KEY",
        actionHandlers: DigiaActionHandlers(
            customKV: { payload in handleCustomAction(payload) },
            deepLink: { url in navigate(to: url) },
            openURL: { url in openInAppBrowser(url) }
        )
    )
)
```

Handlers can be replaced after initialization. Passing `nil` clears the override, so deep links
and URLs return to SDK handling while Custom KV returns to a no-op.

```swift
Digia.setCustomKVHandler { payload in handleCustomAction(payload) }
Digia.setCustomKVHandler(nil) // for example, when leaving the owning screen
```

### Render an experience

```swift
import DigiaEngage
import SwiftUI

struct ContentView: View {
    var body: some View {
        DigiaHost {
            DUIFactory.shared.createInitialPage()
        }
    }
}
```

### Render a slot

```swift
DigiaSlot("hero-banner")
```

### UIKit

UIKit apps use views instead of SwiftUI's `DigiaHost` and `DigiaSlot`, with the same names as on Android.

Make `DigiaHostViewController` the window's root, holding your own root controller:

```swift
window.rootViewController = DigiaHostViewController(content: navigationController)
```

It draws campaigns above every screen you push, every tab and every split column, and lets touches through
to your views unless one is showing. Your screens keep their status bar style, home indicator and
orientation choices. `window.rootViewController` is then this controller; reach yours through `content`.

If your app cannot change its window's root, add a `DigiaHostView` as the last, full-screen subview of
**each** screen's view instead. A host in one screen's view works only while that screen is on screen.

```swift
let host = DigiaHostView(frame: view.bounds)
host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
view.addSubview(host) // last, so it draws on top
```

Do not add a `DigiaHostView` directly to the view of a `UINavigationController`, `UITabBarController`,
`UISplitViewController` or `UIPageViewController` (those treat a child controller as one of their own
screens), nor straight to a `UIWindow`. It draws nothing there and logs a warning.

Without a host, a campaign is accepted but never drawn, and is dropped as `timeout` after 15 seconds.

Show an inline campaign with a `DigiaSlotView`. Pin its position and width and let the content set the
height; it takes no space while its placement has no campaign.

```swift
let slot = DigiaSlotView()
slot.placementKey = "hero-banner" // or set it in Interface Builder
stack.addArrangedSubview(slot)
```

Report screens so campaigns can target them, either with `DigiaNavigationScreenObserver` as a
navigation controller's delegate (keep a strong reference to it) or with `digiaScreen("Home")` from
`viewDidAppear`.

## Plugins

Digia Engage has a plugin architecture for CEP integrations.

```swift
Digia.register(YourCEPPlugin())
```

Available plugins:

- [DigiaEngageCleverTap](https://github.com/Digia-Technology-Private-Limited/digia_engage_clevertap_ios)

## Sample App

A sample app is included in `SampleApp/`. It links the local Swift package (`DigiaEngageSample.xcodeproj` → package at `..`). To run it:

```bash
open SampleApp/DigiaEngageSample.xcodeproj
```

Select the **DigiaEngageSample** scheme and run on an iOS 16+ simulator (Xcode resolves package dependencies automatically).

## License

[BSL 1.1](LICENSE) — Business Source License 1.1. Source available; production use requires a license from Digia Technology.

---

Built with ❤️ by the [Digia](https://digia.tech) team
