import Foundation
import SwiftUI
@testable import DigiaEngage
import Testing

@MainActor
@Suite("DigiaEngage", .serialized)
struct DigiaEngageTests {
    @Test("defaults config to production error logging and debug flavor")
    func defaultsConfig() {
        let config = DigiaConfig(apiKey: "prod_123")

        #expect(config.apiKey == "prod_123")
        #expect(config.logLevel == .error)
        #expect(config.environment == .production)

        if case .debug(let branchName) = config.flavor {
            #expect(branchName == nil)
        } else {
            Issue.record("Expected debug flavor by default")
        }
    }

    @Test("initialize is idempotent")
    func initializeIsIdempotent() async {
        let first = DigiaConfig(apiKey: "first")
        let second = DigiaConfig(apiKey: "second", environment: .sandbox)
        SDKInstance.shared.resetForTesting()

        // Seed config synchronously to avoid a network-call suspension point that would
        // allow concurrent tests to interfere via resetForTesting().
        SDKInstance.shared.markInitializedForTesting(with: first)

        // A second initialize call should hit the guard and return immediately (no await inside).
        try? await Digia.initialize(second)

        #expect(SDKInstance.shared.config == first)
    }

    @Test("register replaces and tears down the previous plugin")
    func registerReplacesPlugin() {
        SDKInstance.shared.resetForTesting()
        let first = TestPlugin(identifier: "first")
        let second = TestPlugin(identifier: "second")

        Digia.register(first)
        Digia.register(second)

        #expect(first.teardownCount == 1)
        #expect(first.setupCount == 1)
        #expect(second.setupCount == 1)
        #expect(second.teardownCount == 0)
    }

    @Test("setCurrentScreen forwards the screen name to the active plugin")
    func setCurrentScreenForwardsToPlugin() {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(identifier: "plugin")
        Digia.register(plugin)

        Digia.setCurrentScreen("checkout")

        #expect(SDKInstance.shared.currentScreen == "checkout")
        #expect(plugin.forwardedScreens == ["checkout"])
    }

    @Test("onCampaignTriggered routes inline payloads into the inline controller")
    func routesInlinePayloadsIntoInlineController() {
        SDKInstance.shared.resetForTesting()

        let payload = InAppPayload(
            id: "campaign-inline",
            content: InAppPayloadContent(
                type: "inline",
                placementKey: "hero_banner",
                title: "Inline title"
            )
        )

        SDKInstance.shared.onCampaignTriggered(payload)

        #expect(SDKInstance.shared.inlineController.getCampaign("hero_banner") == payload)
        #expect(SDKInstance.shared.controller.activePayload == nil)
    }

    @Test("campaign-key inline story payloads route into the inline controller")
    func routesInlineStoryCampaignsIntoInlineController() throws {
        SDKInstance.shared.resetForTesting()

        let campaign = try #require(CampaignModel.fromJson([
            "id": "story-campaign-id",
            "campaignKey": "story-campaign",
            "campaignType": "inline",
            "templateConfig": [
                "templateType": "story",
                "slotKey": "story_strip",
                "items": [
                    [
                        "type": "image",
                        "url": "https://example.com/story.png",
                        "duration": 3000,
                    ]
                ],
            ],
        ]))
        SDKInstance.shared.campaignStore.populate([campaign])

        let payload = InAppPayload(
            id: "story-campaign",
            content: InAppPayloadContent(type: "inline")
        )

        SDKInstance.shared.onCampaignTriggered(payload)

        #expect(SDKInstance.shared.inlineController.getCampaign("story_strip")?.id == "story-campaign")
        #expect(SDKInstance.shared.inlineController.getStoryConfig("story_strip")?.items.count == 1)
        #expect(SDKInstance.shared.inlineController.getCarouselConfig("story_strip") == nil)
    }

    @Test("onCampaignTriggered routes modal payloads into the overlay controller")
    func routesModalPayloadsIntoOverlayController() {
        SDKInstance.shared.resetForTesting()

        let payload = InAppPayload(
            id: "campaign-modal",
            content: InAppPayloadContent(type: "dialog", title: "Modal title")
        )

        SDKInstance.shared.onCampaignTriggered(payload)

        #expect(SDKInstance.shared.controller.activePayload == payload)
    }

    @Test("onCampaignInvalidated clears matching modal and inline payloads")
    func invalidationClearsMatchingPayloads() {
        SDKInstance.shared.resetForTesting()

        let modal = InAppPayload(
            id: "campaign-modal",
            content: InAppPayloadContent(type: "dialog")
        )
        let inline = InAppPayload(
            id: "campaign-inline",
            content: InAppPayloadContent(type: "inline", placementKey: "hero_banner")
        )

        SDKInstance.shared.onCampaignTriggered(modal)
        SDKInstance.shared.onCampaignTriggered(inline)
        SDKInstance.shared.onCampaignInvalidated("campaign-modal")
        SDKInstance.shared.onCampaignInvalidated("campaign-inline")

        #expect(SDKInstance.shared.controller.activePayload == nil)
        #expect(SDKInstance.shared.inlineController.getCampaign("hero_banner") == nil)
    }

    @Test("slot placeholder registration is delegated to the active plugin")
    func placeholderRegistrationDelegatesToPlugin() {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(identifier: "plugin")
        plugin.placeholderIDToReturn = 42
        Digia.register(plugin)

        let id = SDKInstance.shared.registerPlaceholderForSlot(
            propertyID: "hero_banner"
        )

        #expect(id == 42)
        #expect(plugin.placeholderRegistrations.count == 1)
        #expect(plugin.placeholderRegistrations.first == "hero_banner")

        SDKInstance.shared.deregisterPlaceholderForSlot(42)
        #expect(plugin.deregisteredPlaceholderIDs == [42])
    }

    @Test("payload content decodes placementKey directly")
    func payloadContentDecodesPlacementKey() throws {
        let data = Data("""
        {
          "type": "inline",
          "placementKey": "hero_banner",
          "viewId": "hero_component",
          "args": { "name": "Ada" }
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(InAppPayloadContent.self, from: data)

        #expect(decoded.placementKey == "hero_banner")
        #expect(decoded.args == ["name": .string("Ada")])
    }

    @Test("release local-first config resolver loads the typed app config fixture")
    func releaseLocalFirstConfigResolverLoadsFixture() throws {
        guard let fixtureURL = Bundle.module.url(
            forResource: "app_config_fixture",
            withExtension: "json"
        ) else {
            Issue.record("Fixture not found")
            return
        }

        let config = DigiaConfig(
            apiKey: "prod_123",
            flavor: .release(
                initStrategy: .localFirst,
                appConfigPath: fixtureURL.path,
                functionsPath: "unused"
            )
        )

        let resolved = try DigiaConfigResolver(config: config).getConfig()

        #expect(resolved.initialRoute == "samples-list-page")
        #expect(resolved.version == 7)
        #expect(resolved.pages.keys.sorted() == ["country-detail", "samples-list-page"])
        #expect(resolved.components?.keys.sorted() == ["hero-card"])
        #expect(resolved.rest.baseUrl == "https://app.digia.tech/hydrator/api")
        #expect(resolved.theme.colors?.light["primary"] == "#a39cdd")
    }

    @Test("initialize stores the resolved release app config in the runtime store")
    func initializeStoresResolvedReleaseAppConfig() async throws {
        guard let fixtureURL = Bundle.module.url(
            forResource: "app_config_fixture",
            withExtension: "json"
        ) else {
            Issue.record("Fixture not found")
            return
        }

        SDKInstance.shared.resetForTesting()

        let config = DigiaConfig(
            apiKey: "prod_123",
            flavor: .release(
                initStrategy: .localFirst,
                appConfigPath: fixtureURL.path,
                functionsPath: "unused"
            )
        )

        try await Digia.initialize(config)

        #expect(SDKInstance.shared.appConfigStore.appConfig?.initialRoute == "samples-list-page")
        #expect(SDKInstance.shared.appConfigStore.isPage("samples-list-page") == true)
        #expect(SDKInstance.shared.appConfigStore.page("samples-list-page")?.slug == "samples-list-page")
        #expect(SDKInstance.shared.appConfigStore.component("hero-card")?.uid == "hero-card")
    }

    @Test("render payload resolves theme token colors from the typed app config")
    func renderPayloadResolvesThemeTokenColorsFromTheAppConfig() throws {
        guard let fixtureURL = Bundle.module.url(
            forResource: "app_config_fixture",
            withExtension: "json"
        ) else {
            Issue.record("Fixture not found")
            return
        }

        let config = DigiaConfig(
            apiKey: "prod_123",
            flavor: .release(
                initStrategy: .localFirst,
                appConfigPath: fixtureURL.path,
                functionsPath: "unused"
            )
        )

        let resolved = try DigiaConfigResolver(config: config).getConfig()
        let store = AppConfigStore()
        store.update(resolved)
        let payload = RenderPayload(appConfigStore: store)

        #expect(payload.resolveColor("primary") != nil)
        #expect(payload.resolveColor("#a39cdd") != nil)
    }

    @Test("common props decode flattened style values")
    func commonPropsDecodeFlattenedStyleValues() throws {
        let commonProps: CommonProps = try decode("""
        {
          "visibility": true,
          "align": "topLeft",
          "padding": "32,32,32,32",
          "margin": "0,9,0,32",
          "backgroundColor": "backgroundPrimary",
          "width": "311",
          "height": "28"
        }
        """)

        #expect(commonProps.align == "topLeft")
        #expect(commonProps.visibility == .value(true))
        #expect(commonProps.style?.padding?.edgeInsets.top == 32)
        #expect(commonProps.style?.margin?.edgeInsets.top == 9)
        #expect(commonProps.style?.bgColor == .value("backgroundPrimary"))
        #expect(commonProps.style?.width == .expression("311"))
        #expect(commonProps.style?.height == .expression("28"))
    }

    @Test("text props decode nested typography")
    func textPropsDecodeNestedTypography() throws {
        let props: TextProps = try decode("""
        {
          "text": "Mountains",
          "alignment": "left",
          "textStyle": {
            "textColor": "contentPrimary",
            "fontToken": {
              "font": {
                "fontFamily": "Space Grotesk",
                "weight": "bold",
                "size": 36
              }
            }
          }
        }
        """)

        #expect(props.text == .value("Mountains"))
        #expect(props.alignment == .value("left"))
        #expect(props.textStyle?.textColor == "contentPrimary")
        #expect(props.fontDescriptor?.fontFamily == "Space Grotesk")
        #expect(props.fontDescriptor?.weight == "bold")
        #expect(props.fontDescriptor?.size == 36)
    }

    @Test("theme font tokens decode kebab-case family and style values")
    func themeFontTokensDecodeKebabCaseFamilyAndStyleValues() throws {
        let config = try DigiaAppConfig.decode(jsonObject: [
            "appSettings": ["initialRoute": "home"],
            "pages": ["home": ["uid": "home"]],
            "rest": [:],
            "theme": [
                "colors": ["light": [:]],
                "fonts": [
                    "headingSmall": [
                        "size": 20,
                        "weight": "medium",
                        "font-family": "Inter",
                        "height": 1.25,
                        "style": "normal",
                    ],
                ],
            ],
            "version": 1,
        ])

        #expect(config.theme.fonts?["headingSmall"]?.size == 20)
        #expect(config.theme.fonts?["headingSmall"]?.weight == "medium")
        #expect(config.theme.fonts?["headingSmall"]?.fontFamily == "Inter")
        #expect(config.theme.fonts?["headingSmall"]?.style == false)
    }

    @Test("button props decode nested text and icon metadata")
    func buttonPropsDecodeNestedTextAndIconMetadata() throws {
        let props: ButtonProps = try decode("""
        {
          "isDisabled": false,
          "defaultStyle": {
            "backgroundColor": "backgroundSecondary",
            "padding": "12,6,12,6",
            "alignment": "centerRight",
            "height": "28",
            "width": "137"
          },
          "text": {
            "text": "Explore Now",
            "maxLines": 1,
            "overflow": "ellipsis",
            "textStyle": {
              "textColor": "contentPrimary",
              "fontToken": {
                "font": {
                  "fontFamily": "Poppins",
                  "weight": "medium",
                  "size": 11
                }
              }
            }
          },
          "disabledStyle": {
            "disabledTextColor": "contentTertiary",
            "disabledIconColor": "contentTertiary"
          },
          "trailingIcon": {
            "iconData": {
              "pack": "material",
              "key": "chevron.right"
            },
            "iconSize": 14,
            "iconColor": "contentPrimary"
          },
          "shape": {
            "value": "roundedRect",
            "borderColor": "#2563EB",
            "borderStyle": "solid",
            "borderWidth": 2,
            "borderRadius": "6,6,6,6"
          }
        }
        """)

        #expect(props.isDisabled == .value(false))
        #expect(props.defaultStyle?.backgroundColor == "backgroundSecondary")
        #expect(props.defaultStyle?.width == .expression("137"))
        #expect(props.text?.text == .value("Explore Now"))
        #expect(props.text?.maxLines == .value(1))
        #expect(props.text?.overflow == .value("ellipsis"))
        #expect(props.text?.textStyle?.fontToken?.font?.fontFamily == "Poppins")
        #expect(props.disabledStyle?.disabledTextColor == "contentTertiary")
        #expect(props.trailingIcon?.iconData?.key == "chevron.right")
        #expect(props.shape?.value == "roundedRect")
        #expect(props.shape?.borderColor == "#2563EB")
        #expect(props.shape?.borderStyle == "solid")
        #expect(props.shape?.borderWidth == 2)
    }

    @Test("container props decode constraints, gradient and shadow styles")
    func containerPropsDecodeConstraintsGradientAndShadowStyles() throws {
        let props: ContainerProps = try decode("""
        {
          "width": "240",
          "height": "120",
          "minWidth": "100",
          "minHeight": "60",
          "maxWidth": "360",
          "maxHeight": "240",
          "borderRadius": 12,
          "border": {
            "borderWidth": 2,
            "borderRadius": 10
          },
          "gradiant": {
            "colors": ["#111111", "#eeeeee"]
          },
          "shadow": [
            {
              "color": "#000000",
              "blur": 6,
              "spreadRadius": 2
            }
          ]
        }
        """)

        #expect(props.width == .expression("240"))
        #expect(props.height == .expression("120"))
        #expect(props.minWidth == .expression("100"))
        #expect(props.maxHeight == .expression("240"))
        #expect(props.border?.borderWidth == 2)
        #expect(props.gradiant?.colors?.count == 2)
        #expect(props.shadow?.count == 1)
    }

    @Test("rich text props decode span onClick action flow")
    func richTextPropsDecodeSpanOnClickActionFlow() throws {
        let props: RichTextProps = try decode("""
        {
          "textSpans": [
            {
              "text": "Tap me",
              "onClick": {
                "steps": [
                  {
                    "type": "Action.showToast",
                    "data": {
                      "message": "hello"
                    }
                  }
                ]
              }
            }
          ],
          "maxLines": 2,
          "alignment": "left"
        }
        """)

        #expect(props.textSpans.count == 1)
        #expect(props.textSpans.first?.onClick?.steps.count == 1)
        #expect(props.textSpans.first?.onClick?.steps.first?.type == "Action.showToast")
    }

    @Test("image props decode placeholder error and svg fields")
    func imagePropsDecodePlaceholderErrorAndSvgFields() throws {
        let props: ImageProps = try decode("""
        {
          "imageType": "svg",
          "imageSrc": "https://example.com/icon.svg",
          "placeholder": "asset",
          "placeholderSrc": "placeholder_icon",
          "svgColor": "#FF0000",
          "errorImage": {
            "errorEnabled": true,
            "errorSrc": "error_icon"
          }
        }
        """)

        #expect(props.imageType == "svg")
        #expect(props.imageSrc == .value("https://example.com/icon.svg"))
        #expect(props.placeholder == "asset")
        #expect(props.placeholderSrc == "placeholder_icon")
        #expect(props.svgColor == .value("#FF0000"))
        #expect(props.errorImage?.errorEnabled == true)
        #expect(props.errorImage?.errorSrc == "error_icon")
    }

    @Test("image props decode string error image shorthand")
    func imagePropsDecodeStringErrorImageShorthand() throws {
        let props: ImageProps = try decode("""
        {
          "imageSrc": "https://example.com/fallback.png",
          "errorImage": "error_shorthand"
        }
        """)

        #expect(props.errorImage?.errorSrc == "error_shorthand")
    }

    @Test("vw data decodes widget and component categories")
    func vwDataDecodesAllCategories() throws {
        let widget: VWData = try decode("""
        {
          "category": "widget",
          "type": "digia/text",
          "props": { "text": "Hello" }
        }
        """)

        let component: VWData = try decode("""
        {
          "category": "component",
          "componentId": "hero-card",
          "componentArgs": { "headline": "Welcome" }
        }
        """)

        if case let .widget(node) = widget {
            #expect(node.type == "digia/text")
        } else {
            Issue.record("Expected widget node")
        }

        if case let .component(node) = component {
            #expect(node.id == "hero-card")
            #expect(node.args?["headline"] == .string("Welcome"))
        } else {
            Issue.record("Expected component node")
        }
    }

    @Test("expr-or decodes object expression format")
    func exprOrDecodesObjectExpressionFormat() throws {
        struct Wrapper: Decodable {
            let value: ExprOr<String>
        }

        let wrapped: Wrapper = try decode("""
        {
          "value": { "expr": "${state.title}" }
        }
        """)

        #expect(wrapped.value == .expression("${state.title}"))
    }

    @Test("registry returns unsupported widget placeholder for unknown widget type")
    func registryReturnsUnsupportedWidgetType() throws {
        let unknown: VWData = try decode("""
        {
          "category": "widget",
          "type": "digia/notARealWidget",
          "props": {}
        }
        """)

        let registry = DefaultVirtualWidgetRegistry()

        let widget = try registry.createWidget(unknown, parent: nil)
        #expect(widget is VWUnsupported)
    }

    @Test("flex repeats only the first child for dataSource items")
    func flexRepeatsOnlyTheFirstChildForDataSourceItems() throws {
        let firstChild = RenderCountingWidget(
            props: (),
            commonProps: nil,
            parentProps: nil,
            parent: nil,
            refName: "first"
        )
        let secondChild = RenderCountingWidget(
            props: (),
            commonProps: nil,
            parentProps: nil,
            parent: nil,
            refName: "second"
        )

        let flex = VWFlex(
            direction: .vertical,
            props: FlexProps(
                spacing: nil,
                startSpacing: nil,
                endSpacing: nil,
                mainAxisAlignment: nil,
                crossAxisAlignment: nil,
                mainAxisSize: nil,
                isScrollable: nil,
                dataSource: .array([.string("A"), .string("B")])
            ),
            commonProps: nil,
            parentProps: nil,
            childGroups: ["children": [firstChild, secondChild]],
            parent: nil,
            refName: nil
        )
        let payload = RenderPayload(appConfigStore: AppConfigStore())

        let children = try #require(flex.children)
        _ = flex.repeatedChildren(from: children, payload: payload)

        #expect(firstChild.renderCount == 2)
        #expect(secondChild.renderCount == 0)
    }

    @Test("empty inline font token falls back to Flutter default text metrics")
    func emptyInlineFontTokenFallsBackToFlutterDefaultTextMetrics() {
        let descriptor = TextStyleUtil.resolvedFontDescriptor(
            textStyle: TextStyleProps(
                fontToken: FontTokenProps(
                    value: nil,
                    font: FontDescriptorProps(
                        fontFamily: nil,
                        weight: nil,
                        size: nil,
                        height: nil,
                        isItalic: nil,
                        style: nil
                    )
                ),
                textColor: nil,
                textBackgroundColor: nil,
                textDecoration: nil,
                textDecorationColor: nil,
                gradient: nil
            ),
            appConfigStore: AppConfigStore()
        )

        #expect(descriptor?.size == 14)
        #expect(descriptor?.height == 1.5)
        #expect(descriptor?.weight == "regular")
    }

    @Test("button fills width when parent column stretches cross axis")
    func buttonFillsWidthWhenParentColumnStretchesCrossAxis() {
        let parent = VWFlex(
            direction: .vertical,
            props: FlexProps(
                spacing: nil,
                startSpacing: nil,
                endSpacing: nil,
                mainAxisAlignment: nil,
                crossAxisAlignment: "stretch",
                mainAxisSize: nil,
                isScrollable: nil,
                dataSource: nil
            ),
            commonProps: nil,
            parentProps: nil,
            childGroups: nil,
            parent: nil,
            refName: nil
        )
        let widget = VWButton(
            props: ButtonProps(
                buttonState: nil,
                isDisabled: .value(false),
                disabledStyle: nil,
                defaultStyle: ButtonVisualStyle(
                    backgroundColor: nil,
                    padding: nil,
                    elevation: nil,
                    alignment: nil,
                    height: nil,
                    width: nil,
                    disabledTextColor: nil,
                    disabledIconColor: nil,
                    shadowColor: nil
                ),
                text: ButtonTextProps(
                    text: .value("Tap me"),
                    textStyle: nil,
                    maxLines: nil,
                    overflow: nil
                ),
                leadingIcon: nil,
                trailingIcon: nil,
                shape: nil,
                onClick: ActionFlow(steps: [])
            ),
            commonProps: nil,
            parentProps: nil,
            parent: parent,
            refName: nil
        )

        #expect(widget.shouldFillWidthInParentFlex() == true)
    }

    @Test("image fill only stretches when both dimensions are explicit")
    func imageFillOnlyStretchesWhenBothDimensionsAreExplicit() {
        #expect(VWImage.shouldStretchToFillFrame(fit: "fill", hasExplicitWidth: true, hasExplicitHeight: true) == true)
        #expect(VWImage.shouldStretchToFillFrame(fit: "fill", hasExplicitWidth: true, hasExplicitHeight: false) == false)
        #expect(VWImage.shouldStretchToFillFrame(fit: "fill", hasExplicitWidth: false, hasExplicitHeight: true) == false)
        #expect(VWImage.shouldStretchToFillFrame(fit: "cover", hasExplicitWidth: true, hasExplicitHeight: true) == false)
    }

    @Test("button does not fill width in centered column when only height is set")
    func buttonDoesNotFillWidthInCenteredColumnWhenOnlyHeightIsSet() {
        let parent = VWFlex(
            direction: .vertical,
            props: FlexProps(
                spacing: nil,
                startSpacing: nil,
                endSpacing: nil,
                mainAxisAlignment: nil,
                crossAxisAlignment: "center",
                mainAxisSize: nil,
                isScrollable: nil,
                dataSource: nil
            ),
            commonProps: nil,
            parentProps: nil,
            childGroups: nil,
            parent: nil,
            refName: nil
        )
        let widget = VWButton(
            props: ButtonProps(
                buttonState: nil,
                isDisabled: .value(false),
                disabledStyle: nil,
                defaultStyle: ButtonVisualStyle(
                    backgroundColor: nil,
                    padding: nil,
                    elevation: nil,
                    alignment: nil,
                    height: .value(56),
                    width: nil,
                    disabledTextColor: nil,
                    disabledIconColor: nil,
                    shadowColor: nil
                ),
                text: ButtonTextProps(
                    text: .value("Claim Now"),
                    textStyle: nil,
                    maxLines: nil,
                    overflow: nil
                ),
                leadingIcon: nil,
                trailingIcon: nil,
                shape: nil,
                onClick: ActionFlow(steps: [])
            ),
            commonProps: nil,
            parentProps: nil,
            parent: parent,
            refName: nil
        )

        #expect(widget.shouldFillWidthInParentFlex() == false)
    }

    @Test("registry assigns actual container as child parent")
    func registryAssignsActualContainerAsChildParent() throws {
        let node: VWData = try decode("""
        {
          "category": "widget",
          "type": "digia/column",
          "props": {
            "crossAxisAlignment": "stretch"
          },
          "children": {
            "children": [
              {
                "category": "widget",
                "type": "digia/button",
                "props": {
                  "text": {
                    "text": "Tap me"
                  },
                  "onClick": {
                    "steps": []
                  }
                }
              }
            ]
          }
        }
        """)

        let registry = DefaultVirtualWidgetRegistry()
        let widget = try registry.createWidget(node, parent: nil)
        let column = try #require(widget as? VWFlex)
        let button = try #require(column.children?.first as? VWButton)

        #expect(button.parent === column)
        #expect(button.shouldFillWidthInParentFlex() == true)
    }

    @Test("virtual widget registry builds typed widgets from the stored app config")
    func virtualWidgetRegistryBuildsBasicWidgetsFromStoredAppConfig() throws {
        guard let fixtureURL = Bundle.module.url(
            forResource: "app_config_fixture",
            withExtension: "json"
        ) else {
            Issue.record("Fixture not found")
            return
        }

        let config = DigiaConfig(
            apiKey: "prod_123",
            flavor: .release(
                initStrategy: .localFirst,
                appConfigPath: fixtureURL.path,
                functionsPath: "unused"
            )
        )

        let resolved = try DigiaConfigResolver(config: config).getConfig()
        let store = AppConfigStore()
        store.update(resolved)

        let root = try #require(store.page("samples-list-page")?.renderRoot)
        let registry = DefaultVirtualWidgetRegistry()
        let widget = try registry.createWidget(root, parent: nil)

        if let scaffold = widget as? VWScaffold {
            let bodyWidget = scaffold.childOf("body") as? VWFlex
            #expect(bodyWidget != nil)
            #expect(bodyWidget?.children?.count == 4)
            #expect(bodyWidget?.children?.first is VWText)
        } else {
            Issue.record("Expected scaffold widget")
        }
    }

    @Test("virtual widget existential dispatch respects common props visibility")
    func virtualWidgetExistentialDispatchRespectsCommonPropsToWidgetOverride() {
        let widget = RenderCountingWidget(
            props: (),
            commonProps: CommonProps(visibility: .value(false), align: nil, style: nil),
            parentProps: nil,
            parent: nil,
            refName: "counting"
        )
        let payload = RenderPayload(appConfigStore: AppConfigStore())

        let existential: VirtualWidget = widget
        _ = existential.toWidget(payload)

        #expect(widget.renderCount == 0)
    }
}

private func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private final class TestPlugin: DigiaCEPPlugin {
    let identifier: String
    var setupCount = 0
    var teardownCount = 0
    var forwardedScreens: [String] = []
    var placeholderIDToReturn: Int?
    var placeholderRegistrations: [String] = []
    var deregisteredPlaceholderIDs: [Int] = []

    init(identifier: String) {
        self.identifier = identifier
    }

    func setup(delegate: DigiaCEPDelegate) {
        setupCount += 1
    }

    func forwardScreen(_ name: String) {
        forwardedScreens.append(name)
    }

    func registerPlaceholder(propertyID: String) -> Int? {
        placeholderRegistrations.append(propertyID)
        return placeholderIDToReturn
    }

    func deregisterPlaceholder(_ id: Int) {
        deregisteredPlaceholderIDs.append(id)
    }

    func notifyEvent(_ event: DigiaExperienceEvent, payload: InAppPayload) {}

    func healthCheck() -> DiagnosticReport {
        DiagnosticReport(isHealthy: true)
    }

    func teardown() {
        teardownCount += 1
    }
}

@MainActor
private final class RenderCountingWidget: VirtualLeafStatelessWidget<Void> {
    private(set) var renderCount = 0

    override func render(_ payload: RenderPayload) -> AnyView {
        renderCount += 1
        return AnyView(EmptyView())
    }
}
