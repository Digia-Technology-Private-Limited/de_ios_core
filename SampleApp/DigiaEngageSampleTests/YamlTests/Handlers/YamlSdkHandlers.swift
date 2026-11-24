import Foundation
import UIKit
@testable import DigiaEngage

/// Public `Digia` calls, app lifecycle and the clock.
/// Mirrors `handlers/sdk.dart`.
let yamlSdkHandlers: [String: YamlHandler] = [
    "setCurrentScreen": { world, args in
        Digia.setCurrentScreen(name: args["name"] as? String ?? "")
        await Task.yield()
        await world.settle()
    },
    "setUserId": { world, args in
        let userId = args["userId"] as? String ?? ""
        let userHash = args["userHash"] as? String
        whenRunning(world) {
            if let userHash {
                Digia.setUserId(userId, userHash: userHash)
            } else {
                Digia.setUserId(userId)
            }
        }
    },
    "clearUserId": { world, _ in whenRunning(world) { Digia.clearUserId() } },
    "setUserAttributes": { world, args in
        let attributes = args["attributes"] as? [String: Any] ?? [:]
        guard world.launched else {
            // Before initialize the SDK ignores it, as a host app would see.
            world.preLaunch.append { setUserAttributes(attributes) }
            return
        }
        // The awaitable public call, so the sync it starts has answered; a
        // held /userContext leaves it running and the test goes on.
        try await world.untilDoneOrHeld("setUserAttributes", endpoint: "userContext") {
            await Digia.setUserAttributes(attributes)
        }
    },
    "trackEvent": { world, args in
        let name = args["name"] as? String ?? ""
        let properties = args["properties"] as? [String: Any] ?? [:]
        whenRunning(world) { Digia.trackEvent(name: name, properties: properties) }
    },
    "setCampaignsSuppressed": { world, args in
        let suppressed = args["suppressed"] as? Bool ?? false
        whenRunning(world) { Digia.setCampaignsSuppressed(suppressed) }
    },
    "clearInlineContent": { _, args in
        Digia.clearInlineContent((args["keys"] as? [Any] ?? []).map { "\($0)" })
    },
    "clearAllInlineContent": { _, _ in Digia.clearAllInlineContent() },
    "setThemeMode": { world, args in
        Digia.setThemeMode(try themeMode(world, args["mode"] as? String ?? ""))
    },
    // iOS has no public `Digia.flushAnalytics`; this is what one would call.
    "flushAnalytics": { world, _ in
        whenRunning(world) { SDKInstance.shared.services?.flushAnalytics() }
    },
    "stopApp": { world, _ in world.stop() },
    "background": { world, _ in
        world.inBackground = true
        // Real iOS posts willResignActive before didEnterBackground; the
        // story rail pauses on the former (like the harness's resignActive),
        // sessions on the latter. Post both, in order.
        NotificationCenter.default.post(
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    },
    "foreground": { world, _ in
        world.inBackground = false
        // Real iOS posts both when coming back; the story views and video
        // playback resume on didBecomeActive (a willEnterForeground alone
        // leaves strip videos paused, so the rotation would never restart).
        NotificationCenter.default.post(
            name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.post(
            name: UIApplication.didBecomeActiveNotification, object: nil)
        // Let the async notification observers kick off any foreground refresh
        // before settle() checks network.inFlightCount.
        try? await Task.sleep(nanoseconds: 20_000_000)
    },
    "advanceTime": { world, args in
        let by = (args["by"] as! YamlDuration).milliseconds
        // The wall clock moves first, whole: what the survey stamps while the
        // waits below fire (a question viewed) reads the end of the step, as
        // a frame drawn after the jump would.
        world.time.advance(byMs: by)
        let (nanoseconds, overflow) = UInt64(by).multipliedReportingOverflow(by: 1_000_000)
        await world.clock.advance(byNanoseconds: overflow ? UInt64.max / 2 : nanoseconds)
        // Fires every wait that came due on the moved clock (in the
        // foreground; a backgrounded app fires them on `foreground`).
        if world.launched { SDKInstance.shared.engine.waits.schedule() }
        await world.settle()
    },
    "setTime": { world, args in
        let text = args["time"] as? String ?? ""
        let formatter = ISO8601DateFormatter()
        var date = formatter.date(from: text)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = formatter.date(from: text)
        }
        guard let date else {
            throw YamlTestFailure(
                "setTime: not an ISO-8601 time",
                expected: "like 2026-09-30T10:00:00Z",
                actual: text,
                line: world.step.line)
        }
        world.time.setWall(Int64(date.timeIntervalSince1970 * 1000))
    },
    "assertAnonymousId": assertAnonymousId,
]

/// The anonymous ID the SDK reports: empty before initialize, the install's
/// saved ID after, never one made up early. Before any launch the SDK is
/// reset first (with seeded storage applied but kept for the launch), as a
/// fresh process reading the ID before initializing it would.
@MainActor private func assertAnonymousId(_ world: YamlWorld, _ args: [String: Any]) throws {
    guard let want = args["value"] as? String else {
        throw YamlTestFailure(
            "assertAnonymousId: needs a value",
            expected: "value: the expected anonymous ID (\"\" before initialize)",
            line: world.step.line)
    }
    if !world.launched {
        world.applySeedsKeepingQueued()
        SDKInstance.shared.resetForTesting()
    }
    let got = Digia.anonymousId
    if got != want {
        throw YamlTestFailure(
            "anonymous ID",
            expected: want.isEmpty ? "empty (before initialize)" : want,
            actual: got.isEmpty ? "empty" : got,
            line: world.step.line)
    }
}

/// The synchronous public `setUserAttributes`, not its async overload.
/// Mirrors what a host app calling it before `initialize` gets.
private func setUserAttributes(_ attributes: [String: Any]) {
    Digia.setUserAttributes(attributes)
}

/// Runs [call] now while the app runs; before `launchApp` (or after
/// `stopApp`) there is no process yet, so the next launch makes the call
/// after its reset and before `initialize`, as a host app that calls the SDK
/// before initializing it does.
@MainActor private func whenRunning(_ world: YamlWorld, _ call: @escaping @MainActor () -> Void) {
    if world.launched {
        call()
    } else {
        world.preLaunch.append { call() }
    }
}

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
