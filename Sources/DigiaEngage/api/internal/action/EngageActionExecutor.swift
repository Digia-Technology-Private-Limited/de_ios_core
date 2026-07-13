import StoreKit
import UIKit

struct ActionExecutionScope {
    let dismiss: () -> Void
    let next: () -> Void
    let previous: () -> Void

    init(
        dismiss: @escaping () -> Void = {},
        next: @escaping () -> Void = {},
        previous: @escaping () -> Void = {}
    ) {
        self.dismiss = dismiss
        self.next = next
        self.previous = previous
    }
}

@MainActor
final class EngageActionExecutor {
    private let invokeHostAction: (DigiaHostAction, HostActionContext) async -> Bool
    private let invokeLegacyPluginAction: (String, String, CEPTriggerPayload) -> Bool

    init(
        invokeHostAction: @escaping (DigiaHostAction, HostActionContext) async -> Bool,
        invokeLegacyPluginAction: @escaping (String, String, CEPTriggerPayload) -> Bool
    ) {
        self.invokeHostAction = invokeHostAction
        self.invokeLegacyPluginAction = invokeLegacyPluginAction
    }

    func executeActionFlow(
        _ actions: [EngageAction],
        payload: CEPTriggerPayload,
        surface: EngageSurface,
        variables: VariableContext?,
        scope: ActionExecutionScope
    ) async {
        for action in actions {
            await executeAction(
                action,
                payload: payload,
                surface: surface,
                variables: variables,
                scope: scope
            )
        }
    }

    func executeAction(
        _ action: EngageAction,
        payload: CEPTriggerPayload,
        surface: EngageSurface,
        variables: VariableContext?,
        scope: ActionExecutionScope
    ) async {
        let action = action.resolved(with: variables)
        switch action {
        case .dismiss:
            scope.dismiss()
        case .next:
            scope.next()
        case .previous:
            scope.previous()
        case .copyToClipboard(let text):
            UIPasteboard.general.string = text
        case .share(let text):
            ViewControllerUtil.present(
                UIActivityViewController(activityItems: [text], applicationActivities: nil)
            )
        case .requestReview:
            await requestReview()
        case .openUrl, .openDeeplink, .customKV:
            await executeHostAction(action, payload: payload, surface: surface)
        }
    }

    private func executeHostAction(
        _ action: EngageAction,
        payload: CEPTriggerPayload,
        surface: EngageSurface
    ) async {
        guard let hostAction = action.hostAction else { return }
        let context = HostActionContext(
            campaignId: payload.cepCampaignId,
            campaignKey: payload.campaignKey,
            surface: surface
        )
        if await invokeHostAction(hostAction, context) { return }

        let handledByPlugin: Bool
        switch hostAction {
        case .openURL(let url):
            handledByPlugin = invokeLegacyPluginAction("open_url", url, payload)
        case .deepLink(let url):
            handledByPlugin = invokeLegacyPluginAction("deep_link", url, payload)
        case .customKV:
            handledByPlugin = false
        }
        if !handledByPlugin { executeDefaultHostAction(hostAction) }
    }

    private func executeDefaultHostAction(_ action: DigiaHostAction) {
        let rawURL: String
        switch action {
        case .openURL(let url), .deepLink(let url):
            rawURL = url
        case .customKV:
            return
        }
        if let url = URL(string: rawURL) { UIApplication.shared.open(url) }
    }

    private func requestReview() async {
        guard let scene = ViewControllerUtil.findWindowScene() else {
            DigiaLog.warning("requestReview: no window scene; skipping")
            return
        }
        AppStore.requestReview(in: scene)
    }
}
