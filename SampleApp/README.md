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
touch delivery live here: the package's own test bundle has no `UIApplication`, so a synthesized
touch never becomes a gesture there. The suites drive the real SDK through the shared `SdkHarness`
(`../Tests/DigiaEngageTests/Support/SdkHarness.swift`, plus real touches from
`Support/SdkHarness+Touch.swift` and `TouchSynthesizer`): `Actions/` (one suite per authored
action), `FixtureBehaviour/` (ports of Flutter's fixture-behaviour tests that need real touches;
the ones that do not are package tests in `../Tests/DigiaEngageTests/FixtureBehaviour/`), and the anchorless
fixture goldens, whose geometry resolves only in the app's window scene. Every other golden is a
package test. Fixtures come from `<workspace>/sdk_testing_fixtures/`.

The test folder is a filesystem-synchronized group: a new `.swift` file is compiled with no project
change (`Support/CropAssets/` is excluded from the bundle). Its goldens are recorded in
`<workspace>/goldens/ios/`, not here.

`../run-tests.sh` runs these suites after the package suites, with the same tag filter, and merges
their coverage into `coverage/lcov.info`.

```bash
xcodebuild test -project DigiaEngageSample.xcodeproj -scheme DigiaEngageSample \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

When the app launches as the test host it skips `Digia.initialize`, so live campaigns cannot
appear underneath the tests.
