import DigiaEngage
import SwiftUI
import UIKit

// TEMPORARY — PokerBoss tg_suppport_popup live-test harness (core 3.14.1).
@main
struct DigiaEngageSampleApp: App {
    var body: some Scene {
        WindowGroup {
            DigiaSampleRootView()
        }
    }
}

private struct DigiaSampleRootView: View {
    @State private var status = "initializing…"

    var body: some View {
        DigiaHost {
            ZStack {
                Color(white: 0.1).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("PokerBoss repro · core 3.14.1 · sandbox").foregroundStyle(.white)
                    Text(status).font(.caption).foregroundStyle(.gray)
                    Button("Open Digia Debug Settings (Live Test)") {
                        guard let root = UIApplication.shared.connectedScenes
                            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController })
                            .first else { return }
                        var top = root
                        while let presented = top.presentedViewController { top = presented }
                        Digia.presentDebugSettings(from: top)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Set screen App_home") { Digia.setCurrentScreen(name: "App_home") }
                        .buttonStyle(.bordered)
                }
            }
        }
        .task {
            do {
                try await Digia.initialize(
                    DigiaConfig(apiKey: "digia_875438e814f34ff0b33df83071be5c3d", logLevel: .verbose, environment: .sandbox)
                )
                Digia.setCurrentScreen(name: "App_home")
                status = "ready · screen=App_home"
            } catch {
                status = "init failed: \(error.localizedDescription)"
            }
        }
    }
}
