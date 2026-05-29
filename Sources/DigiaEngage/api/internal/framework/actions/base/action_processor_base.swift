import Foundation

struct ActionProcessorContext {
    let appConfig: AppConfigStore
    let scopeContext: (any ExprContext)?
    let localStateStore: StateContext?
    let actionExecutor: ActionExecutor

    init(
        appConfig: AppConfigStore,
        scopeContext: (any ExprContext)? = nil,
        localStateStore: StateContext? = nil,
        actionExecutor: ActionExecutor
    ) {
        self.appConfig = appConfig
        self.scopeContext = scopeContext
        self.localStateStore = localStateStore
        self.actionExecutor = actionExecutor
    }
}
