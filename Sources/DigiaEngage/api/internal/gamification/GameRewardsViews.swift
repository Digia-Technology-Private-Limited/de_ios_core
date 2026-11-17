import SwiftUI
import UIKit

extension Notification.Name {
    /// Posted when a rewards chance opens its game, so the rewards page
    /// dismisses itself instead of sitting under the game surface.
    static let digiaDismissRewardsPage = Notification.Name("tech.digia.engage.dismissRewardsPage")
}

/// Presents the native rewards page over the host app.
enum GameRewardsPresenter {
    @MainActor
    static func presentPage() {
        let host = UIHostingController(rootView: GameRewardsPageView())
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
        }
        ViewControllerUtil.present(host)
    }
}

/// The native rewards page: waiting chances first (soonest expiry first),
/// then active, used and expired rewards. Plain list, no speculative chrome.
@MainActor
struct GameRewardsPageView: View {
    @ObservedObject private var sdk = SDKInstance.shared
    @Environment(\.dismiss) private var dismiss
    @State private var expiredExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Rewards").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            content
        }
        .onReceive(NotificationCenter.default.publisher(for: .digiaDismissRewardsPage)) { _ in
            dismiss()
        }
        .onAppear { sdk.refreshRewards() }
    }

    @ViewBuilder
    private var content: some View {
        if let response = sdk.rewardsResponse, !response.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !response.chances.isEmpty {
                        waitingSection(response.chances)
                    }
                    if !response.active.isEmpty {
                        rewardSection(title: "Your rewards", rewards: response.active)
                    }
                    if !response.used.isEmpty {
                        rewardSection(title: "Used", rewards: response.used)
                    }
                    if !response.expiredGrants.isEmpty || !response.expiredChances.isEmpty {
                        DisclosureGroup("Expired", isExpanded: $expiredExpanded) {
                            VStack(alignment: .leading, spacing: 12) {
                                rewardList(response.expiredGrants)
                                expiredChanceList(response.expiredChances)
                            }
                        }
                        .font(.headline)
                    }
                }
                .padding()
            }
        } else if sdk.rewardsLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(sdk.rewardsResponse?.emptyMessage ?? "Nothing here yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func waitingSection(_ chances: [GameRewardChance]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Waiting to play").font(.headline)
            ForEach(chances, id: \.chanceId) { chance in
                Button(action: { sdk.gamification.openGameForRewardsChance(chance) }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chance.rewardsPageTitle
                            ?? sdk.gamification.rewardsCampaignTitle(for: chance.campaignId)
                            ?? chance.format ?? chance.campaignId)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Text(timeLeft(chance))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !chance.playable {
                            Text("Unavailable")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!chance.playable)
            }
        }
    }

    private func timeLeft(_ chance: GameRewardChance) -> String {
        guard let expires = chance.expiresAt else { return "" }
        let seconds = Int(expires.timeIntervalSince(Date()))
        guard seconds > 0 else { return "Expired" }
        if seconds >= 86400 { return "\(seconds / 86400)d left" }
        if seconds >= 3600 { return "\(seconds / 3600)h left" }
        return "\(max(1, seconds / 60))m left"
    }

    private func rewardSection(title: String, rewards: [GameReward]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            rewardList(rewards)
        }
    }

    private func rewardList(_ rewards: [GameReward]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rewards.indices, id: \.self) { index in
                rewardRow(rewards[index])
            }
        }
    }

    private func rewardRow(_ reward: GameReward) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = reward.name {
                Text(title).font(.subheadline)
            }
            if let instructions = reward.howToUse ?? reward.description {
                Text(instructions).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if let code = reward.code {
                    Text(code).font(.subheadline.monospaced())
                    Button("Copy") { UIPasteboard.general.string = code }
                        .font(.subheadline)
                }
                if let deepLink = reward.ctaDeepLink {
                    Button(reward.ctaLabel ?? "Use now") {
                        sdk.gamification.openRewardDeepLink(deepLink)
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private func expiredChanceList(_ chances: [GameExpiredChance]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(chances, id: \.chanceId) { chance in
                VStack(alignment: .leading, spacing: 4) {
                    Text(chance.rewardsPageTitle
                        ?? sdk.gamification.rewardsCampaignTitle(for: chance.campaignId)
                        ?? chance.campaignId)
                        .font(.subheadline)
                    Text("Expired")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

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
