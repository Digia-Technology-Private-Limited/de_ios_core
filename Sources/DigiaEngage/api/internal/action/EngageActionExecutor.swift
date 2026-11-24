import StoreKit
import UIKit

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// The OS calls the SDK's actions end in. `live` is the only value the SDK uses; a test
/// swaps `current` to record the calls instead of leaving the app, and
/// `SDKInstance.resetForTesting` puts `live` back.
@MainActor
struct ActionPlatform {
    var open: (URL) -> Void
    var copy: (String) -> Void
    var share: (String) -> Void
    var requestReview: () -> Void

    static let live = ActionPlatform(
        open: { UIApplication.shared.open($0) },
        copy: { UIPasteboard.general.string = $0 },
        share: {
            ViewControllerUtil.present(
                UIActivityViewController(activityItems: [$0], applicationActivities: nil)
            )
        },
        requestReview: {
            guard let scene = ViewControllerUtil.findWindowScene() else {
                log.e("requestReview() ignored — no window scene")
                return
            }
            if #available(iOS 16, *) {
                AppStore.requestReview(in: scene)
            } else {
                SKStoreReviewController.requestReview(in: scene)
            }
        }
    )

    static var current = live
}

@MainActor
struct LocalActionExecutor {
    private let dismiss: (() -> Void)?
    private let next: (() -> Void)?
    private let previous: (() -> Void)?
    private let showStory: ((Int) -> Void)?

    init(
        dismiss: (() -> Void)? = nil,
        next: (() -> Void)? = nil,
        previous: (() -> Void)? = nil,
        showStory: ((Int) -> Void)? = nil
    ) {
        self.dismiss = dismiss
        self.next = next
        self.previous = previous
        self.showStory = showStory
    }

    func execute(_ action: EngageAction) -> Bool {
        switch action {
        case .dismiss: execute("dismiss", callback: dismiss)
        case .next: execute("next", callback: next)
        case .previous: execute("previous", callback: previous)
        case .showStory(let index):
            execute("show_story", callback: showStory.map { callback in { callback(index) } })
        default: false
        }
    }

    private func execute(_ name: String, callback: (() -> Void)?) -> Bool {
        if let callback {
            callback()
        } else {
            log.e("Local action ignored — not supported by this campaign surface (action=\(name))")
        }
        return true
    }
}

@MainActor
final class GlobalActionExecutor {
    private let copy: (String) -> Void
    private let share: (String) -> Void
    private let requestReview: () -> Void

    init(
        copy: @escaping (String) -> Void = { ActionPlatform.current.copy($0) },
        share: @escaping (String) -> Void = { ActionPlatform.current.share($0) },
        requestReview: @escaping () -> Void = { ActionPlatform.current.requestReview() }
    ) {
        self.copy = copy
        self.share = share
        self.requestReview = requestReview
    }

    func execute(_ action: EngageAction) -> Bool {
        switch action {
        case .copyToClipboard(let text): copy(text)
        case .share(let text): share(text)
        case .requestReview: requestReview()
        default: return false
        }
        return true
    }
}

@MainActor
final class HostActionExecutor {
    private var customKVHandler: CustomKVHandler?
    private var deepLinkHandler: DeepLinkHandler?
    private var openURLHandler: OpenURLHandler?
    private var legacyActionHandler: (String, String) -> Bool = { _, _ in false }
    private let openURL: (String) -> Void

    init(openURL: @escaping (String) -> Void = {
        guard let url = URL(string: $0) else { return }
        ActionPlatform.current.open(url)
    }) {
        self.openURL = openURL
    }

    func configure(_ handlers: DigiaActionHandlers) {
        customKVHandler = handlers.customKV
        deepLinkHandler = handlers.deepLink
        openURLHandler = handlers.openURL
    }

    func clearHandlers() {
        customKVHandler = nil
        deepLinkHandler = nil
        openURLHandler = nil
    }

    func setCustomKVHandler(_ handler: CustomKVHandler?) {
        customKVHandler = handler
    }

    func setDeepLinkHandler(_ handler: DeepLinkHandler?) {
        deepLinkHandler = handler
    }

    func setOpenURLHandler(_ handler: OpenURLHandler?) {
        openURLHandler = handler
    }

    func setLegacyActionHandler(_ handler: @escaping (String, String) -> Bool) {
        legacyActionHandler = handler
    }

    @discardableResult
    func execute(_ action: EngageAction, campaignKey: String?) throws -> Bool {
        switch action {
        case .customKV(let payload):
            if let customKVHandler {
                try customKVHandler(payload)
            } else {
                log.w(
                    "customKV action has no host handler — skipped",
                    campaign: campaignKey,
                    stage: .interaction,
                    reason: TimelineReason.actionHandlerMissing,
                    extras: ["action_type": "customKV"]
                )
            }
        case .openDeeplink(let url):
            if let deepLinkHandler {
                try deepLinkHandler(url)
            } else if !legacyActionHandler("deep_link", url) {
                openURL(url)
            }
        case .openUrl(let url):
            if let openURLHandler {
                try openURLHandler(url)
            } else if !legacyActionHandler("open_url", url) {
                openURL(url)
            }
        default:
            return false
        }
        return true
    }
}

@MainActor
final class EngageActionExecutor {
    private let globalActionExecutor: GlobalActionExecutor
    private let hostActionExecutor: HostActionExecutor

    init(
        globalActionExecutor: GlobalActionExecutor = GlobalActionExecutor(),
        hostActionExecutor: HostActionExecutor
    ) {
        self.globalActionExecutor = globalActionExecutor
        self.hostActionExecutor = hostActionExecutor
    }

    func executeActionFlow(
        _ actions: [EngageAction],
        variables: VariableContext?,
        campaignKey: String?,
        localActionExecutor: LocalActionExecutor
    ) async {
        for action in actions {
            await executeAction(
                action,
                variables: variables,
                campaignKey: campaignKey,
                localActionExecutor: localActionExecutor
            )
        }
    }

    func executeAction(
        _ action: EngageAction,
        variables: VariableContext?,
        campaignKey: String?,
        localActionExecutor: LocalActionExecutor
    ) async {
        do {
            let action = action.resolved(with: variables)
            if action.hasEmptyPayload { return }
            if localActionExecutor.execute(action) { return }
            if globalActionExecutor.execute(action) { return }
            try hostActionExecutor.execute(action, campaignKey: campaignKey)
        } catch {
            log.e("Action step failed", error: error.localizedDescription)
        }
    }
}
