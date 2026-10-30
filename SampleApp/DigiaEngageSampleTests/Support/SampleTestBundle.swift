import Foundation
import SDWebImage

/// The test bundle's principal class (`INFOPLIST_KEY_NSPrincipalClass` in the target's build settings).
/// XCTest makes one when it loads the bundle, before any test runs, so every test lays out on the
/// reference phone (`GoldenScreen`) whatever simulator runs it.
///
/// It also empties SDWebImage's caches once per run. SDWebImage answers from them before it makes a
/// request, and its disk cache outlives runs, so a picture this simulator fetched in an earlier run would
/// stand in for the one `StubBackend` serves.
@objc(DigiaEngageSampleTestBundle)
final class SampleTestBundle: NSObject {
    override init() {
        super.init()
        MainActor.assumeIsolated { GoldenScreen.pin() }
        SDImageCache.shared.clearMemory()
        SDImageCache.shared.diskCache.removeAllData()
    }
}
