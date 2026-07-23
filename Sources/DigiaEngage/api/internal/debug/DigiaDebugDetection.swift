import Foundation

/// Whether the host app is a debug-eligible (non-App-Store) build.
///
/// `#if DEBUG` inside this framework is **not** reliable here: `DigiaEngage` is
/// distributed to most consumers (including the React Native bridge) as a prebuilt
/// **binary** xcframework, built once by Digia's own release pipeline (see
/// `DigiaEngage.podspec` — "Production podspec — FAT binary distribution"). Code
/// inside that binary was compiled with *Digia's* build configuration, not the
/// consuming app's, so `#if DEBUG` would always resolve to whatever Digia used
/// (almost certainly Release) regardless of how the host app itself was built —
/// silently making anything gated on it unreachable for every real app. Reading
/// the host app's own embedded provisioning profile instead works correctly
/// regardless of how this framework itself was linked (SPM source or the prebuilt
/// xcframework), since it inspects the *app bundle*, not this framework's code.
enum DigiaDebugDetection {
    static func isDebugBuild() -> Bool {
        // Simulator builds never carry an embedded provisioning profile at all
        // (they aren't code-signed the way device builds are), but are always
        // non-production by construction — most day-to-day development happens
        // here, so this must resolve `true`, not fall through to "no profile found".
        #if targetEnvironment(simulator)
        return true
        #else
        return hasDebugProvisioningProfile()
        #endif
    }

    /// `get-task-allow` is `true` only for development/ad-hoc-debuggable builds
    /// (an app signed for a debugger to attach), and always `false` for App Store /
    /// TestFlight distribution — the standard technique third-party SDKs use to
    /// detect "not a real production install" independent of compiler flags.
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
