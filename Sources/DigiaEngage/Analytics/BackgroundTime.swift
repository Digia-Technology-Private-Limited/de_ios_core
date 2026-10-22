import UIKit

/// Asks iOS for time to finish work after the app leaves the foreground.
/// Without it, iOS suspends the app within seconds and an in-flight send is
/// frozen until the next launch.
@MainActor
protocol BackgroundTimeProvider: AnyObject {
    /// Starts a background task; nil when iOS grants none. [expiration] runs
    /// on the main thread when the time is about to run out.
    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int?
    func end(_ id: Int)
}

/// The real provider: `UIApplication.beginBackgroundTask` (about 30 s).
@MainActor
final class UIKitBackgroundTime: BackgroundTimeProvider {
    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int? {
        let id = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { expiration() }
        }
        return id == .invalid ? nil : id.rawValue
    }

    func end(_ id: Int) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id))
    }
}

/// Runs [work] inside one background task, ending the task exactly once:
/// when [work] finishes, or when iOS says the time is up — whichever is first.
/// iOS terminates an app that lets a task expire without ending it. Work cut
/// off at expiry loses nothing: unsent events stay queued for the next launch.
@MainActor
func withBackgroundTime(
    _ provider: BackgroundTimeProvider,
    name: String,
    _ work: () async -> Void
) async {
    @MainActor final class Grant {
        var id: Int?
        func end(_ provider: BackgroundTimeProvider) {
            guard let id else { return }
            self.id = nil
            provider.end(id)
        }
    }
    let grant = Grant()
    grant.id = provider.begin(name: name) { [weak grant] in grant?.end(provider) }
    await work()
    grant.end(provider)
}
