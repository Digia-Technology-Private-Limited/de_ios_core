import DigiaEngage
import SwiftUI

@main
struct DigiaEngageSampleApp: App {
    /// True when the app is launched as the host of `DigiaEngageSampleTests`. The tests drive the
    /// SDK themselves, so the app must not start it against live campaigns underneath them.
    private let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        guard !isTestHost else { return }
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
            if isTestHost {
                Text("Running DigiaEngageSampleTests")
            } else {
                DigiaSampleRootView()
            }
        }
    }
}

private struct DigiaSampleRootView: View {
    @State private var initializationState: InitializationState = .idle

    var body: some View {
        DigiaHost {
            // `DUIFactory` was removed with the DUI framework (4bc23bd); a plain host screen.
            Text("Digia Engage Sample")
        }
        .overlay(alignment: .top) {
            if case .failed(let message) = initializationState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.red)
                    .clipShape(Capsule())
                    .padding(.top, 12)
            }
        }
        .task {
            guard initializationState == .idle else { return }
            initializationState = .initializing

            do {
                try await Digia.initialize(
                    DigiaConfig(apiKey: "69d3dc5e4d3eed4271b8c259")
                )
                initializationState = .ready
            } catch {
                initializationState = .failed(error.localizedDescription)
            }
        }
    }
}

private enum InitializationState: Equatable {
    case idle
    case initializing
    case ready
    case failed(String)
}
