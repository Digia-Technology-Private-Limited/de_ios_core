import Foundation
@testable import DigiaEngage

/// Stands in for iOS: records every call the SDK's actions make instead of leaving the app.
@MainActor
final class RecordingPlatform {
    private(set) var opened: [String] = []
    private(set) var copied: [String] = []
    private(set) var shared: [String] = []
    private(set) var reviewRequests = 0

    var actionPlatform: ActionPlatform {
        ActionPlatform(
            open: { [weak self] in self?.opened.append($0.absoluteString) },
            copy: { [weak self] in self?.copied.append($0) },
            share: { [weak self] in self?.shared.append($0) },
            requestReview: { [weak self] in self?.reviewRequests += 1 }
        )
    }
}
