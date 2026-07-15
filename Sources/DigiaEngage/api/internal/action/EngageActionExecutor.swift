import StoreKit
import UIKit

/// Actions a rendered campaign can perform within its own UI.
@MainActor
struct LocalActionExecutor {
    private let dismiss: (() -> Void)?
    private let next: (() -> Void)?
    private let previous: (() -> Void)?

    init(
        dismiss: (() -> Void)? = nil,
        next: (() -> Void)? = nil,
        previous: (() -> Void)? = nil
    ) {
        self.dismiss = dismiss
        self.next = next
        self.previous = previous
    }

    func execute(_ action: EngageAction) -> Bool {
        switch action {
        case .dismiss: execute("dismiss", callback: dismiss)
        case .next: execute("next", callback: next)
        case .previous: execute("previous", callback: previous)
        default: false
        }
    }

    private func execute(_ name: String, callback: (() -> Void)?) -> Bool {
        if let callback {
            callback()
        } else {
            DigiaLog.warning("Local action '\(name)' is not supported by this campaign surface")
        }
        return true
    }
}

/// SDK-owned actions shared by every campaign surface.
@MainActor
final class GlobalActionExecutor {
    private let copy: (String) -> Void
    private let share: (String) -> Void
    private let requestReview: () -> Void

    init(
        copy: @escaping (String) -> Void = { UIPasteboard.general.string = $0 },
        share: @escaping (String) -> Void = {
            ViewControllerUtil.present(
                UIActivityViewController(activityItems: [$0], applicationActivities: nil)
            )
        },
        requestReview: @escaping () -> Void = {
            guard let scene = ViewControllerUtil.findWindowScene() else {
                DigiaLog.warning("requestReview: no window scene; skipping")
                return
            }
            if #available(iOS 16, *) {
                AppStore.requestReview(in: scene)
            } else {
                SKStoreReviewController.requestReview(in: scene)
            }
        }
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

/// Host overrides and SDK fallbacks for host-owned actions.
@MainActor
final class HostActionExecutor {
    private var customKVHandler: CustomKVHandler?
    private var deepLinkHandler: DeepLinkHandler?
    private var openURLHandler: OpenURLHandler?
    private let openURL: (String) -> Void

    init(openURL: @escaping (String) -> Void = {
        guard let url = URL(string: $0) else { return }
        UIApplication.shared.open(url)
    }) {
        self.openURL = openURL
    }

    func configure(_ handlers: DigiaActionHandlers) {
        customKVHandler = handlers.customKV
        deepLinkHandler = handlers.deepLink
        openURLHandler = handlers.openURL
    }

    func clearHandlers() {
        configure(DigiaActionHandlers())
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

    @discardableResult
    func execute(_ action: EngageAction) throws -> Bool {
        switch action {
        case .customKV(let payload):
            try customKVHandler?(payload)
        case .openDeeplink(let url):
            if let deepLinkHandler { try deepLinkHandler(url) } else { openURL(url) }
        case .openUrl(let url):
            if let openURLHandler { try openURLHandler(url) } else { openURL(url) }
        default:
            return false
        }
        return true
    }
}

/// Resolves and executes an authored action flow in order on the main actor.
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
        localActionExecutor: LocalActionExecutor
    ) async {
        for action in actions {
            await executeAction(
                action,
                variables: variables,
                localActionExecutor: localActionExecutor
            )
        }
    }

    func executeAction(
        _ action: EngageAction,
        variables: VariableContext?,
        localActionExecutor: LocalActionExecutor
    ) async {
        do {
            let action = action.resolved(with: variables)
            if localActionExecutor.execute(action) { return }
            if globalActionExecutor.execute(action) { return }
            try hostActionExecutor.execute(action)
        } catch {
            DigiaLog.error("Action step failed: \(error.localizedDescription)")
        }
    }
}
