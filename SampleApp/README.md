# DigiaEngageSample

Sample iOS app for the `DigiaEngage` Swift package.

## Run

- Open `DigiaEngageSample.xcodeproj` (the app depends on the Swift package at the repo root via **File → Add Package**-style local reference `..`).
- Select the `DigiaEngageSample` scheme
- Run on an iOS 16+ simulator

## Config

Update `DigiaEngageSampleApp.swift` with a valid API key if you need to hit real config.
The sample app now initializes the SDK from `DigiaSampleRootView`, so startup failures are surfaced in-app instead of being silently dropped.

## Tests

`DigiaEngageSampleTests` is a unit-test target hosted by this app. Tests that need real UIKit
touch delivery live here: the package's own test bundle (`swift test` / `run-tests.sh`) has no
`UIApplication`, so a synthesized touch never becomes a gesture there. `FloaterTapTests` taps the
PiP and story floater through `TouchSynthesizer` and checks the production tap handlers ran.
`FixtureBehaviour/*AnalyticsChainTests` drive every surface through `SdkHarness` and read the Digia
`/track` chain off `StubBackend` beside the CEP's markings (`./run-sample-tests.sh analytics`); tests
that hit a known bug run and fail, each with a `// Fails today:` comment.

```bash
xcodebuild test -project DigiaEngageSample.xcodeproj -scheme DigiaEngageSample \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

When the app launches as the test host it skips `Digia.initialize`, so live campaigns cannot
appear underneath the tests.
