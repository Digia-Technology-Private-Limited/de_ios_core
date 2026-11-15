import Foundation
import SnapshotTesting
import SwiftUI
import UIKit
@testable import DigiaEngage

/// What a command does. [args] are already checked and typed by the contract.
/// Fail with [YamlTestFailure] (expected/actual).
/// Mirrors `World`/`YamlHandler` in `world.dart`.
typealias YamlHandler = @MainActor (YamlWorld, [String: Any]) async throws -> Void

/// Everything one YAML test shares between its steps. Created fresh per file,
/// holding the test-only fakes the driver owns: the network, the CEP plugin
/// and the diagnostic sink. The UI is real: the SDK host mounted in a window.
@MainActor
final class YamlWorld {
    init(yamlDir: URL) {
        self.yamlDir = yamlDir
        let box = YamlCampaignBox()
        self.campaignBox = box
        cep = YamlRecordingCep()
        logSink = YamlLogSink()
        platform = RecordingPlatform()
        network = YamlNetworkFake(bundle: { [box] in box.value })
    }

    /// Folder of the YAML file; fixture paths resolve against it.
    let yamlDir: URL

    /// The step being run, for handlers that report its position.
    var step: YamlStep!

    /// What `mockApi: getCampaigns` set; what the SDK is served on launch.
    /// Backed by a lock-protected box: the network fake reads it off the
    /// main actor, and the fake is built before `self` exists.
    var campaigns: [[String: Any]] {
        get { campaignBox.value }
        set { campaignBox.value = newValue }
    }
    private let campaignBox: YamlCampaignBox

    let network: YamlNetworkFake
    let cep: YamlRecordingCep
    let logSink: YamlLogSink
    let platform: RecordingPlatform

    var window: UIWindow?
    var onPhone = false

    /// Whether `launchApp` has booted the SDK since the last `stopApp`.
    var launched = false

    /// The network log size at the `clearState` launch; `mockApi` rules set
    /// before `launchApp` survive across launches within one test.
    var apiBaseline = 0

    /// The network log size after each boot settled; analytics events the
    /// disk queue held over from an earlier test are flushed before it.
    var eventBaseline = 0

    private var sinkAttached = false

    // MARK: - Boot, relaunch, teardown

    /// Boots the real SDK serving [campaigns] through the fake network, with
    /// the recording CEP attached, and mounts the real host. A second launch
    /// without `clearState` is a relaunch over the same storage.
    func bootForTest(clearState: Bool, mountPhone: Bool) async throws {
        let sdk = SDKInstance.shared
        sdk.resetForTesting()
        if !sinkAttached {
            sinkAttached = true
            DigiaLogger.registerSink(logSink)
        }
        if clearState {
            network.clearLog()
            let defaults = UserDefaults(suiteName: SdkHarness.storageSuite)
            defaults?.removePersistentDomain(forName: SdkHarness.storageSuite)
            // Marks storage as already migrated, so no launch runs the
            // migrator (mirrors `SdkHarness.create`).
            defaults?.set(1, forKey: "storage.version")
        }
        ComponentTestHost.enableAccessibilityAutomation()
        GoldenFonts.install()
        ActionPlatform.current = platform.actionPlatform
        guard let client = sdk.networkClient as? URLSessionNetworkClient else {
            throw YamlTestFailure("unexpected network client",
                                  expected: "URLSessionNetworkClient",
                                  line: step.line)
        }
        client.overrideForTesting = network
        // The SDK keeps the last screen; a kept one would fire screen rules at ready.
        sdk.setCurrentScreen("")
        try await Digia.initialize(DigiaConfig(
            apiKey: "test-api-key", fontFamily: GoldenFonts.family))
        // A failed fetch still settles the state machine (ready with an
        // empty store, or failed): either way the launch goes on, like the
        // harness, and the steps assert what that means.
        try await waitUntil("the SDK to settle", timeout: 10) {
            sdk.sdkState != .initializing
        }
        Digia.register(cep)
        try await waitUntil("the plugin is attached", timeout: 5) {
            cep.host != nil
        }
        cep.flush()
        try mount(mountPhone: mountPhone)
        launched = true
        // The analytics queue is in memory, but flush what boot queued so
        // `assertEvents` reads only this test's, then mark the log.
        sdk.services?.analyticsService?.flush()
        await settle()
        eventBaseline = network.logCount
    }

    private func mount(mountPhone: Bool) throws {
        onPhone = mountPhone
        if mountPhone {
            let device = ViewImageConfig.engageGolden
            let size = device.size ?? CGSize(width: 390, height: 844)
            let window = ComponentTestHost.makeWindow(frame: CGRect(origin: .zero, size: size))
            // No device scrim: the campaign's own barrier dims the host, exactly
            // as the hand-written goldens mount it (`makeRealOverlayWindow`
            // passes `scrimColor: nil`).
            let rootVC = ComponentTestHost.makeDeviceHost(
                device: device, style: .striped, scrimColor: nil, showHomeIndicator: false)
            let host = UIHostingController(rootView: DigiaHost { Color.clear })
            rootVC.addChild(host)
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.backgroundColor = .clear
            rootVC.view.addSubview(host.view)
            host.didMove(toParent: rootVC)
            window.rootViewController = rootVC
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            // The dialog and full-screen goldens lay out against the golden
            // device's screen and insets, exactly as the hand-written goldens
            // do: `NudgeGoldenTests` pins the screen via `makeWindow` and the
            // reference geometry here, with no `pinSafeArea` correction.
            if servesDialogOrFullscreen {
                let insets = device.safeArea
                activeFloaterWindowGeometryOverride = (
                    CGRect(origin: .zero, size: size),
                    EdgeInsets(
                        top: insets.top, leading: insets.left,
                        bottom: insets.bottom, trailing: insets.right))
            }
            self.window = window
        } else {
            let window = ComponentTestHost.makeWindow(
                frame: CGRect(origin: .zero, size: SdkHarness.screen))
            let host = UIHostingController(rootView: DigiaHost { Text("App home") })
            window.rootViewController = host
            window.makeKeyAndVisible()
            self.window = window
        }
        ComponentTestHost.drainRunLoop(for: 0.3)
    }

    /// Whether a served campaign lays out against the golden device's screen:
    /// a dialog or full-screen surface.
    private var servesDialogOrFullscreen: Bool {
        campaigns.contains { campaign in
            let container = (campaign["templateConfig"] as? [String: Any])?["container"]
                as? [String: Any]
            let display = (container?["displayType"] as? String)?.lowercased() ?? ""
            return display == "dialog" || display == "fullscreen"
                || display == "full_screen" || display == "full-screen"
        }
    }

    /// Process death: what is on screen and all in-memory SDK state go; the
    /// fake persistent storage stays. The next `launchApp` without
    /// `clearState` is a relaunch over it.
    func stop() {
        if let window {
            window.isHidden = true
            window.resignKey()
        }
        window = nil
        onPhone = false
        activeFloaterWindowGeometryOverride = nil
        SDKInstance.shared.resetForTesting()
        launched = false
    }

    func tearDown() {
        stop()
        network.releaseAll()
        if sinkAttached {
            sinkAttached = false
            DigiaLogger.unregisterSink(logSink)
        }
    }

    // MARK: - Reading the test

    /// A `json` argument: a path ending `.json` is read from [yamlDir];
    /// anything else is already inline JSON.
    func json(_ value: Any?) throws -> Any? {
        guard let path = value as? String, path.hasSuffix(".json") else {
            return value
        }
        let url = yamlDir.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url),
              var text = String(data: data, encoding: .utf8)
        else {
            throw YamlTestFailure(
                "fixture not found",
                expected: "a file at \(url.path)",
                line: step.line)
        }
        if let workspace = FixtureLoader.workspaceURL() {
            text = FixtureLoader.resolveAssetOrigin(in: text, workspaceUrl: workspace)
        }
        guard let parsed = try? JSONSerialization.jsonObject(
            with: Data(text.utf8), options: [.fragmentsAllowed])
        else {
            throw YamlTestFailure(
                "fixture is not JSON",
                expected: "JSON in \(url.path)",
                line: step.line)
        }
        return parsed
    }

    /// Lets main-actor work scheduled so far (a delivery's routing, analytics
    /// flushes) run. Before `launchApp` there is nothing to wait for.
    /// Buffered CEP triggers deliver the moment the host is ready.
    func settle() async {
        guard launched else { return }
        cep.flush()
        try? await Task.sleep(nanoseconds: 50_000_000)
        window?.layoutIfNeeded()
        ComponentTestHost.drainRunLoop(for: 0.05)
    }

    func finish() async {
        await settle()
    }

    func waitUntil(
        _ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Task.isCancelled { throw CancellationError() }
            if Date() > deadline {
                throw YamlTestFailure("timed out waiting for \(what)", line: step.line)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The running SDK; fails the step if `launchApp` has not run yet.
    var sdk: SDKInstance {
        get throws {
            guard launched else {
                throw YamlTestFailure(
                    "the app is not running",
                    expected: "launchApp before this command",
                    line: step.line)
            }
            return SDKInstance.shared
        }
    }
}

// MARK: - The fake network

/// The campaigns the fake bundle answers with, shared with the world across
/// isolation boundaries.
final class YamlCampaignBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [[String: Any]] = []

    var value: [[String: Any]] {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Everything the network fake knows in one test: per-endpoint rules,
/// one-shot rules, the request log and held requests. Installed as the SDK's
/// real client's override, so the real client, image pipeline and retry
/// stack run; only answers are scripted. Test-only: no `Sources/` change.
final class YamlNetworkFake: NetworkClient, @unchecked Sendable {
    /// What `mockApi` set for one endpoint.
    struct Rule {
        /// `hang: true`: the request stays pending until `releaseApi`.
        var hang = false
        var status = 200
        var body: Any? = nil
        var networkError = false
    }

    /// Answers the campaign bundle with the world's current campaigns, like
    /// the harness default; everything else gets the accepted answer.
    init(bundle: @escaping () -> [[String: Any]]) {
        self.bundle = bundle
    }

    private let bundle: () -> [[String: Any]]
    private let lock = NSLock()
    private var rules: [String: Rule] = [:]
    private var once: [String: [Rule]] = [:]
    private var log: [(endpoint: String, body: Any?)] = []
    private var held: [String: [CheckedContinuation<NetworkResponse?, Never>]] = [:]

    /// What `mockApi` set for one endpoint, and the one-shot queue.
    func setRule(_ rule: Rule, for endpoint: String) {
        lock.withLock { rules[endpoint] = rule }
    }

    func addOnce(_ rule: Rule, for endpoint: String) {
        lock.withLock { once[endpoint, default: []].append(rule) }
    }

    func removeRule(for endpoint: String) {
        _ = lock.withLock { rules.removeValue(forKey: endpoint) }
    }

    func clearLog() {
        lock.withLock { log.removeAll() }
    }

    var logCount: Int {
        lock.withLock { log.count }
    }

    /// The logged requests from [index] on.
    func logSnapshot(from index: Int) -> [(endpoint: String, body: Any?)] {
        lock.withLock { Array(log.dropFirst(index)) }
    }

    /// Logical endpoint name to the URL path suffix the SDK calls.
    static let paths: [String: String] = [
        "getCampaigns": "/api/v1/engage/sdk/getCampaignBundle",
        "getSdkConfig": "/api/v1/engage/sdk/getSdkConfig",
        "track": "/api/v1/engage/sdk/track",
        "session": "/api/v1/engage/sdk/session",
        "surveySubmission": "/api/v1/engage/sdk/recordSubmission",
        "recordComponents": "/api/v1/engage/sdk/recordComponents",
        "recordPageCapture": "/api/v1/engage/sdk/recordPageCapture",
    ]

    /// iOS has no user-context endpoint: `setUserId` stays local. Known to
    /// the contract, but never requested — `assertApi` on it reads an honest
    /// zero and anything else fails as the behaviour difference it is.
    static func endpointName(for url: URL) -> String {
        let absolute = url.absoluteString
        for (name, suffix) in paths where absolute.hasSuffix(suffix) {
            return name
        }
        return absolute
    }

    private func decide(url: URL, body: Data?) -> (
        endpoint: String, decoded: Any?, rule: Rule?
    ) {
        let endpoint = Self.endpointName(for: url)
        var decoded: Any? = nil
        if let body {
            decoded = (try? JSONSerialization.jsonObject(
                with: body, options: [.fragmentsAllowed])) ?? String(data: body, encoding: .utf8)
        }
        let rule: Rule? = lock.withLock {
            log.append((endpoint, decoded))
            if var queue = once[endpoint], !queue.isEmpty {
                let next = queue.removeFirst()
                once[endpoint] = queue
                return next
            }
            return rules[endpoint]
        }
        return (endpoint, decoded, rule)
    }

    private func answer(_ rule: Rule) -> NetworkResponse? {
        if rule.networkError { return nil }
        let data: Data?
        if let body = rule.body {
            if let text = body as? String {
                data = Data(text.utf8)
            } else {
                data = try? JSONSerialization.data(withJSONObject: body)
            }
        } else {
            data = Data("{}".utf8)
        }
        return NetworkResponse(
            statusCode: rule.status, headers: [:], body: data,
            isSuccessful: (200..<300).contains(rule.status))
    }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        let (endpoint, _, rule) = decide(url: request.url, body: request.body)
        if let rule {
            if rule.hang {
                let heldAnswer = await withCheckedContinuation { continuation in
                    lock.lock()
                    held[endpoint, default: []].append(continuation)
                    lock.unlock()
                }
                if let heldAnswer { return heldAnswer }
            } else if rule.networkError {
                throw URLError(.notConnectedToInternet)
            } else if let response = answer(rule) {
                return response
            }
        }
        return `default`(for: endpoint)
    }

    /// What an unmocked endpoint answers: the bundle serves the world's
    /// campaigns; everything else is accepted.
    func `default`(for endpoint: String) -> NetworkResponse {
        if endpoint == "getCampaigns" {
            let body = try? JSONSerialization.data(withJSONObject:
                ["data": ["response": ["campaigns": bundle()]]])
            return NetworkResponse(statusCode: 200, headers: [:], body: body, isSuccessful: true)
        }
        return NetworkResponse(
            statusCode: 200, headers: [:],
            body: Data(#"{"accepted":1,"rejected":0,"errors":[]}"#.utf8),
            isSuccessful: true)
    }

    /// Answers every held request as the harness would, so none outlives the test.
    func releaseAll() {
        lock.withLock {
            let all = held.values.flatMap { $0 }
            held.removeAll()
            return all
        }.forEach { $0.resume(returning: nil) }
    }

    /// Answers every held request on [endpoint], then stops holding it.
    /// Returns false when nothing was held.
    func release(endpoint: String, with rule: Rule?) -> Bool {
        lock.lock()
        let pending = held.removeValue(forKey: endpoint) ?? []
        if rules[endpoint]?.hang == true { rules.removeValue(forKey: endpoint) }
        lock.unlock()
        guard !pending.isEmpty else { return false }
        for continuation in pending {
            continuation.resume(returning: rule.flatMap(answer) ?? `default`(for: endpoint))
        }
        return true
    }

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        appendLog((Self.endpointName(for: request.url), nil))
        return NetworkResponse(
            statusCode: 200, headers: [:],
            body: Data(#"{"accepted":1,"rejected":0,"errors":[]}"#.utf8),
            isSuccessful: true)
    }

    private func appendLog(_ entry: (endpoint: String, body: Any?)) {
        lock.withLock { log.append(entry) }
    }

    func openSseStream(
        request: NetworkRequest, handler: any SseStreamHandler
    ) -> any CancellableSubscription {
        appendLog((Self.endpointName(for: request.url), nil))
        handler.onOpen()
        return YamlNoopSubscription()
    }
}

private final class YamlNoopSubscription: CancellableSubscription, @unchecked Sendable {
    func cancel() {}
}

// MARK: - The recording CEP plugin

/// What a CEP does in production, reduced to what the driver asserts:
/// holds the host, hands it triggers (buffering what arrives before the host
/// is ready, as the contract says), and records every call the SDK makes.
@MainActor
final class YamlRecordingCep: DigiaCEPPlugin {
    let id = "yaml-test"
    private(set) var host: DigiaCEPHost?

    /// `{ call: setup|teardown|onScreenChanged|trackEvent, ... }`, in order.
    private(set) var calls: [[String: Any]] = []

    /// Every delivery, in delivery order, with the trigger as delivered.
    private(set) var deliveries: [(trigger: CEPTriggerPayload, presentation: any CampaignPresentation)] = []

    private var buffered: [CEPTriggerPayload] = []

    func attach(host: DigiaCEPHost) {
        self.host = host
        calls.append(["call": "setup"])
        flush()
    }

    func detach() {
        calls.append(["call": "teardown"])
        host = nil
    }

    func onScreenChanged(_ screenName: String) {
        calls.append(["call": "onScreenChanged", "screenName": screenName])
    }

    func trackEvent(_ eventName: String, properties: [String: Any]) {
        calls.append(["call": "trackEvent", "name": eventName, "properties": properties])
    }

    func onHostReady() {
        flush()
    }

    /// What the CEP does when its campaign fires. Queued when the host is
    /// not ready yet; dropped payloads never silently vanish — they deliver
    /// once the host is ready.
    func fire(_ payload: CEPTriggerPayload) {
        guard let host, host.isReady else {
            buffered.append(payload)
            return
        }
        deliveries.append((payload, host.deliver(payload)))
    }

    func flush() {
        guard let host, host.isReady else { return }
        for payload in buffered {
            deliveries.append((payload, host.deliver(payload)))
        }
        buffered.removeAll()
    }
}

// MARK: - The diagnostic sink

/// Records every diagnostic record the SDK emits, like the rule-case
/// runner's sink does on Flutter.
final class YamlLogSink: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [TimelineRecord] = []

    var records: [TimelineRecord] { lock.withLock { _records } }

    func accepts(_ record: TimelineRecord) -> Bool { true }
    func emit(_ record: TimelineRecord) { lock.withLock { _records.append(record) } }
}

// MARK: - Partial matching

/// Every key of [want] is in [got] with a matching value; maps recurse, so a
/// nested `properties` may be partial too. Anything else is compared whole.
/// Mirrors `_matches`/`_contains` in the Flutter driver.
enum YamlMatch {
    static func matches(_ got: Any?, _ want: Any?) -> Bool {
        if let wantMap = want as? [String: Any] {
            guard let gotMap = got as? [String: Any] else { return false }
            return wantMap.allSatisfy { key, value in
                gotMap.keys.contains(key) && matches(gotMap[key], value)
            }
        }
        if let wantList = want as? [Any] {
            guard let gotList = got as? [Any], gotList.count == wantList.count else {
                return false
            }
            return zip(gotList, wantList).allSatisfy { matches($0, $1) }
        }
        return equal(got, want)
    }

    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (norm(a), norm(b)) {
        case (.none, .none): return true
        case (.some(let x), .some(let y)): return x == y
        default: return false
        }
    }

    private static func norm(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            // Bool is an NSNumber too: keep true/false distinct from 1/0.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            if CFNumberIsFloatType(number) {
                return String(number.doubleValue)
            }
            return String(number.int64Value)
        }
        return "\(value)"
    }

    /// Canonical JSON for failure output.
    static func json(_ value: Any?) -> String {
        guard let value else { return "null" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(
               withJSONObject: value, options: [.sortedKeys, .prettyPrinted]),
           let text = String(data: data, encoding: .utf8)
        {
            return text
        }
        if let text = value as? String, let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           JSONSerialization.isValidJSONObject(parsed),
           let pretty = try? JSONSerialization.data(
               withJSONObject: parsed, options: [.sortedKeys, .prettyPrinted]),
           let out = String(data: pretty, encoding: .utf8)
        {
            return out
        }
        return "\(value)"
    }
}
