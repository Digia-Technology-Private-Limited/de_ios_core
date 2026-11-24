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
            case .chances(let count, let soonest):
                Button(action: { sdk.gamification.handleRewardsWidgetTap() }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.chancesTitle(count: count))
                            .font(.subheadline)
                        if let ends = gameRewardsEndsIn(soonest) {
                            Text(ends)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .reward(let reward):
                Button(action: { sdk.gamification.handleRewardsWidgetTap() }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reward.name).font(.subheadline)
                        if let detail = reward.detail {
                            Text(detail).font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .empty(let message):
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if sdk.rewardsResponse == nil { sdk.refreshRewards() }
        }
    }

    private static func chancesTitle(count: Int) -> String {
        "\(count) chance" + (count == 1 ? "" : "s") + " waiting"
    }
}
