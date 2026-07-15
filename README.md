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
        from: "3.4.0"
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
pod 'DigiaEngage', '~> 3.4.0'
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
