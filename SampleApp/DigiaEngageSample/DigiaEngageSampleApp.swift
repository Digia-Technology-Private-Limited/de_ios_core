import DigiaEngage
import SwiftUI

@main
struct DigiaEngageSampleApp: App {
    init() {
        // Hosting the test bundle: the tests initialize the SDK themselves, against a fake backend.
        guard !isHostingTests else { return }
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
            // Hosting the test bundle: the tests mount their own DigiaHost, and nothing here may touch
            // the SDK before they install their fake backend.
            if isHostingTests { Color.clear } else { DigiaSampleRootView() }
        }
    }
}

private struct DigiaSampleRootView: View {
    @State private var initializationState: InitializationState = .idle

    var body: some View {
        DigiaHost {
            Color.white
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
            guard !isHostingTests, initializationState == .idle else { return }
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

private var isHostingTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

private enum InitializationState: Equatable {
    case idle
    case initializing
    case ready
    case failed(String)
}
