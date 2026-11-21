import SwiftUI
import UIKit

/// The `digia_rewards_widget` slot content: chances waiting (count, formats,
/// soonest expiry), else the latest unused reward, else the empty state —
/// hidden, or the project's message.
@MainActor
struct GameRewardsWidgetView: View {
    @ObservedObject private var sdk = SDKInstance.shared

    var body: some View {
        Group {
            switch GameRewardsResponse.widgetContent(
                chances: sdk.rewardsResponse?.chances ?? [],
                widget: sdk.rewardsResponse?.widget)
            {
            case .hidden:
                EmptyView()
            case .chances(let count, let formats, let soonest):
                Button(action: { sdk.gamification.handleRewardsWidgetTap() }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.chancesTitle(count: count))
                            .font(.subheadline)
                        if !formats.isEmpty {
                            Text(formats.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let soonest {
                            Text("Ends \(Self.expiryString(soonest))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .reward(let reward):
                Button(action: { sdk.gamification.handleRewardsWidgetTap() }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reward.name ?? "Reward").font(.subheadline)
                        if let code = reward.code {
                            Text(code).font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .empty(let message):
                Text(message ?? "").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if sdk.rewardsResponse == nil { sdk.refreshRewards() }
        }
    }

    private static func chancesTitle(count: Int) -> String {
        "\(count) chance" + (count == 1 ? "" : "s") + " waiting"
    }

    private static func expiryString(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSince(Date()))
        guard seconds > 0 else { return "soon" }
        if seconds >= 86400 { return "in \(seconds / 86400)d" }
        if seconds >= 3600 { return "in \(seconds / 3600)h" }
        return "in \(max(1, seconds / 60))m"
    }
}
