import SwiftUI

@MainActor
struct DUIPageView: View {
    let pageID: String
    let page: PageDefinition
    let root: VWData
    let registry: VirtualWidgetRegistry
    let pageArgs: [String: JSONValue]

    @ObservedObject private var runtime = SDKInstance.shared
    @StateObject private var stateStore: StateContext
    @State private var didRunPageLoad = false

    init(
        pageID: String,
        page: PageDefinition,
        root: VWData,
        registry: VirtualWidgetRegistry,
        pageArgs: [String: JSONValue] = [:]
    ) {
        self.pageID = pageID
        self.page = page
        self.root = root
        self.registry = registry
        self.pageArgs = pageArgs
        let initialState = page.initStateDefs?.mapValues { $0.resolvedValue(in: nil) } ?? [:]
        _stateStore = StateObject(
            wrappedValue: StateContext(namespace: page.uid ?? pageID, initialState: initialState))
    }

    var body: some View {
        let baseContext = StateScopeContext(
            stateContext: stateStore,
            variables: pageArgs.mapValues(\.anyValue),
            enclosing: AppStateExprContext(
                values: runtime.appState.mapValues(\.anyValue),
                streams: runtime.appStateStreams.mapValues { $0 as Any }
            )
        )
        let payload = RenderPayload(
            resources: ResourceProvider(
                fontFactory: runtime.fontFactory, appConfigStore: runtime.appConfigStore),
            scopeContext: baseContext,
            localStateStore: stateStore
        )
        let widget = try? registry.createWidget(root, parent: nil)
        return (widget?.toWidget(payload) ?? AnyView(EmptyView()))
            .onAppear {
                SDKInstance.shared.registerStateContext(self.stateStore)
                if !self.didRunPageLoad {
                    self.didRunPageLoad = true
                    payload.executeAction(
                        self.page.actions?.onPageLoadAction, triggerType: "onPageLoad")
                }
            }
            .onDisappear {
                SDKInstance.shared.unregisterStateContext(self.stateStore)
            }
    }
}
