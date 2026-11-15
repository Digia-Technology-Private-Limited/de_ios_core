import Foundation
import UIKit
@testable import DigiaEngage

/// Public `Digia` calls, app lifecycle and the clock.
/// Mirrors `handlers/sdk.dart`.
let yamlSdkHandlers: [String: YamlHandler] = [
    "setCurrentScreen": { world, args in
        Digia.setCurrentScreen(name: args["name"] as? String ?? "")
    },
    "setUserId": { world, args in
        Digia.setUserId(args["userId"] as? String ?? "")
    },
    "clearUserId": { _, _ in Digia.clearUserId() },
    "setUserAttributes": unsupported(
        "Digia.setUserAttributes is missing on iOS: user attributes can only arrive " +
        "inside the user-context the server sends, which iOS never requests."),
    "trackEvent": unsupported(
        "Digia.trackEvent is missing on iOS: only the CEP plugin's trackEvent hook " +
        "exists, for plugin-owned campaigns."),
    "setCampaignsSuppressed": { _, args in
        Digia.setCampaignsSuppressed(args["suppressed"] as? Bool ?? false)
    },
    "clearInlineContent": { _, args in
        Digia.clearInlineContent((args["keys"] as? [Any] ?? []).map { "\($0)" })
    },
    "clearAllInlineContent": { _, _ in Digia.clearAllInlineContent() },
    "setThemeMode": { world, args in
        Digia.setThemeMode(try themeMode(world, args["mode"] as? String ?? ""))
    },
    "flushAnalytics": unsupported(
        "Digia.flushAnalytics is missing on iOS: the queue flushes itself and " +
        "assertEvents flushes it before reading."),
    "stopApp": { world, _ in world.stop() },
    "background": { _, _ in
        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    },
    "foreground": { _, _ in
        NotificationCenter.default.post(
            name: UIApplication.willEnterForegroundNotification, object: nil)
    },
    "advanceTime": unsupported(
        "the shared SDKInstance has no injectable clock: waits and frequency windows " +
        "read the wall clock. Needs a Sources/ seam before this command can fire timers."),
    "setTime": unsupported(
        "the shared SDKInstance has no injectable clock. Needs a Sources/ seam " +
        "before absolute time can be set."),
]

@MainActor private func themeMode(_ world: YamlWorld, _ mode: String) throws -> DigiaThemeMode {
    switch mode {
    case "light": return .light
    case "dark": return .dark
    case "system", "auto": return .auto
    default:
        throw YamlTestFailure(
            "setThemeMode: unknown mode",
            expected: "light, dark or system",
            actual: mode,
            line: world.step.line)
    }
}
