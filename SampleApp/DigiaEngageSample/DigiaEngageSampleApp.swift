import DigiaEngage
import SwiftUI

@main
struct DigiaEngageSampleApp: App {
    init() {
        Task {
            try await Digia.initialize(
                DigiaConfig(
                    apiKey: "69abfbcb79d23afa245a60ee",
                    logLevel: .verbose
                )
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            DigiaHost {
                DUIFactory.shared.createInitialPage()
            }
        }
     }
}
