import DigiaExpr
import Foundation
@testable import DigiaEngage
import Testing

@MainActor
@Suite("Navigation Actions", .serialized)
struct NavigationActionTests {
    @Test("navigateToPage with openAs bottomSheet maps to showBottomSheet action")
    func navigateToPageBottomSheetMaps() throws {
        let step = ActionStep(
            type: ActionType.navigateToPage.rawValue,
            data: ["openAs": .string("bottomSheet")],
            disableActionIf: nil
        )
        let action = try ActionFactory.makeAction(from: step)
        #expect(action.actionType == .showBottomSheet)
    }

    @Test("navigation processors update runtime navigation and dialog state")
    func navigationAndDialogBehavior() async throws {
        SDKInstance.shared.resetForTesting()
        let configPath = try makeTempConfigFile("""
        {
          "appSettings": { "initialRoute": "home-page" },
          "pages": {
            "home-page": { "uid": "home-page", "slug": "home-page" },
            "next-page": { "uid": "next-page", "slug": "next-page" }
          },
          "components": {
            "sheet_1": { "uid": "sheet_1" },
            "dialog_1": { "uid": "dialog_1" }
          },
          "rest": {},
          "theme": { "colors": { "light": {} } }
        }
        """)
        try await Digia.initialize(
            DigiaConfig(
                apiKey: "test_nav",
                flavor: .release(initStrategy: .localFirst, appConfigPath: configPath, functionsPath: "unused")
            )
        )
        SDKInstance.shared.onNavigationMounted()
        let ctx = context(appConfig: SDKInstance.shared.appConfigStore)

        try await NavigateToPageProcessor().execute(
            action: NavigateToPageAction(disableActionIf: nil, data: ["pageData": .object(["id": .string("next-page")])]),
            context: ctx
        )
        #expect(SDKInstance.shared.navigationController.currentPageID == "next-page")

        try await NavigateBackUntilProcessor().execute(
            action: NavigateBackUntilAction(disableActionIf: nil, data: ["routeNameToPopUntil": .string("/home-page")]),
            context: ctx
        )
        #expect(SDKInstance.shared.navigationController.currentPageID == "home-page")

        try await ShowDialogProcessor().execute(
            action: ShowDialogAction(disableActionIf: nil, data: ["viewData": .object(["id": .string("dialog_1")])]),
            context: ctx
        )
        #expect(SDKInstance.shared.controller.activeDialog?.view.viewID == "dialog_1")

        try await DismissDialogProcessor().execute(
            action: DismissDialogAction(disableActionIf: nil, data: [:]),
            context: ctx
        )
        #expect(SDKInstance.shared.controller.activeDialog == nil)

        try await ShowBottomSheetProcessor().execute(
            action: ShowBottomSheetAction(
                disableActionIf: nil,
                data: ["viewData": .object(["id": .string("sheet_1"), "title": .string("Sheet title")])]
            ),
            context: ctx
        )
        #expect(SDKInstance.shared.controller.activeBottomSheet?.view.viewID == "sheet_1")

        try await HideBottomSheetProcessor().execute(
            action: HideBottomSheetAction(disableActionIf: nil, data: [:]),
            context: ctx
        )
        #expect(SDKInstance.shared.controller.activeBottomSheet == nil)
    }

    private func context(appConfig: AppConfigStore = AppConfigStore()) -> ActionProcessorContext {
        ActionProcessorContext(appConfig: appConfig)
    }
}
