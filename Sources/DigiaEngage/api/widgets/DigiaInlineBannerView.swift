import SwiftUI

struct DigiaInlineBannerView: View {
    let config: InlineBannerConfig
    let payload: CEPTriggerPayload

    private var variables: VariableContext {
        buildVariableContext(schemas: config.variableSchemas, cepVars: payload.variables)
    }

    /// The actions whose payload resolves to a value.
    private var actions: [EngageAction] {
        config.actions.filter { !$0.resolved(with: variables).hasEmptyPayload }
    }

    var body: some View {
        Group {
            if actions.isEmpty {
                banner
            } else {
                banner
                    .contentShape(Rectangle())
                    .onTapGesture(perform: handleTap)
            }
        }
        .padding(EdgeInsets(
            top: config.margin.top,
            leading: config.margin.left,
            bottom: config.margin.bottom,
            trailing: config.margin.right
        ))
        .environment(\.digiaCampaignKey, payload.campaignKey)
    }

    @ViewBuilder
    private var banner: some View {
        if config.image.aspectRatio > 0 {
            image
                .aspectRatio(config.image.aspectRatio, contentMode: .fit)
        } else {
            image
                .frame(maxWidth: .infinity)
                .frame(height: config.image.height)
        }
    }

    private var image: some View {
        ZStack {
            Color(red: 241 / 255, green: 241 / 255, blue: 245 / 255)
            MediaImage(
                url: interpolate(config.image.url, context: variables),
                fit: MediaFit(rawValue: config.image.boxFit.rawValue) ?? .cover,
                blurHash: config.image.placeholder?.stillBlurHash
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: config.image.cornerRadius))
    }

    private func handleTap() {
        let tappable = actions
        let reportedAction = tappable.first?.resolved(with: variables)
        SDKInstance.shared.reportBannerClicked(payload: payload, action: reportedAction)
        Task {
            await SDKInstance.shared.executeActionFlow(
                tappable,
                variables: variables,
                campaignKey: payload.campaignKey,
                localActionExecutor: LocalActionExecutor()
            )
        }
    }
}
