import Foundation

/// Whether the host app is a debug-eligible (non-App-Store) build.
///
/// Not `#if DEBUG`: `DigiaEngage` ships to most consumers as a prebuilt binary
/// xcframework (see `DigiaEngage.podspec`), compiled with Digia's own build
/// config, not the host app's — `#if DEBUG` here would always reflect Digia's
/// build, not the app's. Reading the host's embedded provisioning profile
/// instead inspects the app bundle itself, so it's correct regardless of how
/// this framework was linked.
enum DigiaDebugDetection {
    static func isDebugBuild() -> Bool {
        // Simulator builds carry no provisioning profile but are never production.
        #if targetEnvironment(simulator)
        return true
        #else
        return hasDebugProvisioningProfile() || isTestFlightInstall()
        #endif
    }

    /// TestFlight is a tester-distribution channel, so debug tools are
    /// intentionally available there. TestFlight installs carry a sandbox
    /// receipt ("sandboxReceipt"), while App Store installs get "receipt", so
    /// production stays dark. `appStoreReceiptURL` is deprecated as of the
    /// iOS 18 SDK; `AppTransaction.shared.environment` is the eventual
    /// replacement, kept out for now to avoid the async + StoreKit 2 dependency.
    private static func isTestFlightInstall() -> Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    /// `get-task-allow` is true only for debuggable builds, false for App
    /// Store/TestFlight — the standard way SDKs detect a non-production install.
    private static func hasDebugProvisioningProfile() -> Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1)
        else { return false }

        // The plist is embedded inside a CMS-signed blob — pull out the plist
        // substring between its XML markers before parsing it.
        guard let plistStart = text.range(of: "<?xml"),
              let plistEnd = text.range(of: "</plist>")
        else { return false }

        let plistString = String(text[plistStart.lowerBound..<plistEnd.upperBound])
        guard let plistData = plistString.data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return false }

        return (entitlements["get-task-allow"] as? Bool) ?? false
    }
}
