import Foundation
@testable import DigiaEngage
import Testing

@MainActor
@Suite("EngageActionExecutor", .serialized)
struct EngageActionExecutorTests {
    @Test("installed host handler owns action without fallback")
    func installedHandlerSuppressesFallback() throws {
        var handled: [String] = []
        var fallbacks: [String] = []
        let executor = HostActionExecutor(openURL: { fallbacks.append($0) })
        executor.configure(DigiaActionHandlers(deepLink: { handled.append($0) }))

        try executor.execute(.openDeeplink("medihubrn://cart"))

        #expect(handled == ["medihubrn://cart"])
        #expect(fallbacks.isEmpty)
    }

    @Test("legacy handler runs before URL fallback")
    func legacyHandlerRunsBeforeFallback() throws {
        var legacy: [String] = []
        var fallbacks: [String] = []
        let executor = HostActionExecutor(openURL: { fallbacks.append($0) })
        executor.setLegacyActionHandler { type, url in
            legacy.append("\(type):\(url)")
            return true
        }

        try executor.execute(.openUrl("https://digia.tech"))

        #expect(legacy == ["open_url:https://digia.tech"])
        #expect(fallbacks.isEmpty)
    }

    @Test("typed handler takes precedence over legacy handler")
    func typedHandlerPrecedesLegacyHandler() throws {
        var legacyCalls = 0
        var handled: [String] = []
        let executor = HostActionExecutor()
        executor.setLegacyActionHandler { _, _ in
            legacyCalls += 1
            return true
        }
        executor.configure(DigiaActionHandlers(deepLink: { handled.append($0) }))

        try executor.execute(.openDeeplink("medihubrn://cart"))

        #expect(handled == ["medihubrn://cart"])
        #expect(legacyCalls == 0)
    }

    @Test("clearing host handler restores URL fallback for future actions")
    func clearingHandlerRestoresFallback() throws {
        var handled: [String] = []
        var fallbacks: [String] = []
        let executor = HostActionExecutor(openURL: { fallbacks.append($0) })
        executor.configure(DigiaActionHandlers(openURL: { handled.append($0) }))
        try executor.execute(.openUrl("https://digia.tech/first"))

        executor.setOpenURLHandler(nil)
        try executor.execute(.openUrl("https://digia.tech/second"))

        #expect(handled == ["https://digia.tech/first"])
        #expect(fallbacks == ["https://digia.tech/second"])
    }

    @Test("missing Custom KV handler is a no-op")
    func missingCustomKVHandlerIsNoOp() throws {
        var fallbacks: [String] = []
        let executor = HostActionExecutor(openURL: { fallbacks.append($0) })

        try executor.execute(.customKV(["screen": "cart"]))

        #expect(fallbacks.isEmpty)
    }

    @Test("clearing all handlers restores URL fallbacks and Custom KV no-op")
    func clearingAllHandlersRestoresDefaults() throws {
        var handled: [String] = []
        var fallbacks: [String] = []
        let executor = HostActionExecutor(openURL: { fallbacks.append($0) })
        executor.configure(DigiaActionHandlers(
            customKV: { handled.append(String(describing: $0)) },
            deepLink: { handled.append($0) },
            openURL: { handled.append($0) }
        ))

        executor.clearHandlers()
        try executor.execute(.customKV(["screen": "cart"]))
        try executor.execute(.openDeeplink("medihubrn://cart"))
        try executor.execute(.openUrl("https://digia.tech"))

        #expect(handled.isEmpty)
        #expect(fallbacks == ["medihubrn://cart", "https://digia.tech"])
    }

    @Test("legacy inline fields remain available beside canonical actions")
    func legacyInlineFieldsRemainAvailable() throws {
        let story = try #require(StoryItemConfig.fromJson([
            "type": "image",
            "url": "https://example.com/story.png",
            "ctaAction": ["type": "deepLink", "url": "medihubrn://cart"],
        ]))
        let carousel = try #require(InlineCarouselConfig.fromJson([
            "slotKey": "home",
            "items": [[
                "imageUrl": "https://example.com/card.png",
                "deepLink": "medihubrn://cart",
            ]],
        ]))

        #expect(story.ctaAction == StoryCtaAction(type: "deepLink", url: "medihubrn://cart"))
        #expect(story.actions == [.openDeeplink("medihubrn://cart"), .dismiss])
        #expect(carousel.items.first?.deepLink == "medihubrn://cart")
        #expect(carousel.items.first?.actions == [.openDeeplink("medihubrn://cart")])
    }

    @Test("Inline Story canonical steps stay under ctaAction")
    func inlineStoryCanonicalStepsUseCtaAction() throws {
        let story = try #require(StoryItemConfig.fromJson([
            "type": "image",
            "url": "https://example.com/story.png",
            "ctaAction": [
                "type": "dismiss",
                "steps": [[
                    "type": "Action.customKV",
                    "data": ["payload": ["screen": "cart"]],
                ]],
            ],
        ]))

        #expect(story.actions == [.customKV(["screen": "cart"])])
    }

    @Test("local executor runs the capabilities supplied by a guide")
    func localExecutorRunsGuideCapabilities() {
        var executed: [String] = []
        let executor = LocalActionExecutor(
            dismiss: { executed.append("dismiss") },
            next: { executed.append("next") },
            previous: { executed.append("previous") }
        )

        executor.execute(.dismiss)
        executor.execute(.next)
        executor.execute(.previous)

        #expect(executed == ["dismiss", "next", "previous"])
    }

    @Test("local capability snapshots match each campaign surface")
    func localCapabilityMatrix() {
        func runLocalActions(_ executor: LocalActionExecutor) {
            executor.execute(.dismiss)
            executor.execute(.next)
            executor.execute(.previous)
        }

        var guide: [String] = []
        runLocalActions(LocalActionExecutor(
            dismiss: { guide.append("dismiss") },
            next: { guide.append("next") },
            previous: { guide.append("previous") }
        ))
        var nudge: [String] = []
        runLocalActions(LocalActionExecutor(dismiss: { nudge.append("dismiss") }))
        var story: [String] = []
        runLocalActions(LocalActionExecutor(dismiss: { story.append("dismiss") }))
        let carousel: [String] = []
        runLocalActions(LocalActionExecutor())

        #expect(guide == ["dismiss", "next", "previous"])
        #expect(nudge == ["dismiss"])
        #expect(story == ["dismiss"])
        #expect(carousel.isEmpty)
    }

    @Test("coordinator routes local, global, and host actions")
    func coordinatorClassification() async {
        var executed: [String] = []
        let hostExecutor = HostActionExecutor(openURL: { _ in })
        hostExecutor.configure(DigiaActionHandlers(
            openURL: { executed.append("host:\($0)") }
        ))
        let executor = EngageActionExecutor(
            globalActionExecutor: GlobalActionExecutor(
                copy: { executed.append("global:\($0)") },
                share: { _ in },
                requestReview: {}
            ),
            hostActionExecutor: hostExecutor
        )

        await executor.executeActionFlow(
            [.dismiss, .copyToClipboard("text"), .openUrl("https://digia.tech")],
            variables: nil,
            localActionExecutor: LocalActionExecutor(dismiss: { executed.append("local") })
        )

        #expect(executed == ["local", "global:text", "host:https://digia.tech"])
    }

    @Test("unsupported local action is consumed")
    func unsupportedLocalActionIsConsumed() async {
        var globalCalls = 0
        var hostCalls = 0
        let executor = EngageActionExecutor(
            globalActionExecutor: GlobalActionExecutor(
                copy: { _ in globalCalls += 1 },
                share: { _ in globalCalls += 1 },
                requestReview: { globalCalls += 1 }
            ),
            hostActionExecutor: HostActionExecutor(openURL: { _ in hostCalls += 1 })
        )

        await executor.executeAction(
            .next,
            variables: nil,
            localActionExecutor: LocalActionExecutor()
        )

        #expect(globalCalls == 0)
        #expect(hostCalls == 0)
    }

    @Test("authored action flow resolves values and continues in order")
    func actionFlowResolvesValuesAndContinues() async {
        var deepLinks: [String] = []
        var copied: [String] = []
        let hostExecutor = HostActionExecutor(openURL: { _ in })
        hostExecutor.configure(DigiaActionHandlers(deepLink: { deepLinks.append($0) }))
        let executor = EngageActionExecutor(
            globalActionExecutor: GlobalActionExecutor(
                copy: { copied.append($0) },
                share: { _ in },
                requestReview: {}
            ),
            hostActionExecutor: hostExecutor
        )

        await executor.executeActionFlow(
            [.openDeeplink("medihubrn://{{path}}"), .copyToClipboard("{{product}}")],
            variables: VariableContext(
                values: ["path": "cart", "product": "Shoes"],
                types: ["path": "string", "product": "string"]
            ),
            localActionExecutor: LocalActionExecutor()
        )

        #expect(deepLinks == ["medihubrn://cart"])
        #expect(copied == ["Shoes"])
    }

    @Test("handler failure suppresses fallback and does not stop later steps")
    func handlerFailureIsIsolated() async {
        enum TestError: Error { case handlerFailed }
        var fallbacks: [String] = []
        var copied: [String] = []
        let hostExecutor = HostActionExecutor(openURL: { fallbacks.append($0) })
        hostExecutor.configure(DigiaActionHandlers(
            deepLink: { _ in throw TestError.handlerFailed }
        ))
        let executor = EngageActionExecutor(
            globalActionExecutor: GlobalActionExecutor(
                copy: { copied.append($0) },
                share: { _ in },
                requestReview: {}
            ),
            hostActionExecutor: hostExecutor
        )

        await executor.executeActionFlow(
            [.openDeeplink("medihubrn://cart"), .copyToClipboard("Shoes")],
            variables: nil,
            localActionExecutor: LocalActionExecutor()
        )

        #expect(fallbacks.isEmpty)
        #expect(copied == ["Shoes"])
    }
}
