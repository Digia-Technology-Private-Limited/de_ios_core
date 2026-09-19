import Testing
@testable import DigiaEngage

/// Longhand pin of the troubleshooting timeline's wire vocabulary — the twin of
/// `CEPInterfaceEnumValuesTests` for the symbols that are not already pinned
/// there.
///
/// Every expectation is written out in full on purpose. These strings are a
/// contract between four SDKs and two renderers (the on-device screen and the
/// dashboard), so deriving an expectation from the case name would pin nothing.
@Suite("Timeline wire strings")
struct TimelineWireStringsTests {

    @Test("TimelineStage wires")
    func stageWires() {
        #expect(TimelineStage.session.wire == "session")
        #expect(TimelineStage.fetch.wire == "fetch")
        #expect(TimelineStage.parse.wire == "parse")
        #expect(TimelineStage.trigger.wire == "trigger")
        #expect(TimelineStage.gating.wire == "gating")
        #expect(TimelineStage.render.wire == "render")
        #expect(TimelineStage.interaction.wire == "interaction")
        #expect(TimelineStage.allCases.count == 7)
    }

    @Test("TimelineReason wires")
    func reasonWires() {
        #expect(TimelineReason.sdkInitialized.wire == "sdk_initialized")
        #expect(TimelineReason.pluginRegistered.wire == "plugin_registered")
        #expect(TimelineReason.liveSessionConnected.wire == "live_session_connected")
        #expect(TimelineReason.liveSessionDisconnected.wire == "live_session_disconnected")
        #expect(TimelineReason.bundleFetched.wire == "bundle_fetched")
        #expect(TimelineReason.bundleEmpty.wire == "bundle_empty")
        #expect(TimelineReason.fetchFailedNetwork.wire == "fetch_failed_network")
        #expect(TimelineReason.fetchFailedAuth.wire == "fetch_failed_auth")
        #expect(TimelineReason.malformedCampaignSkipped.wire == "malformed_campaign_skipped")
        #expect(TimelineReason.unknownDesignToken.wire == "unknown_design_token")
        #expect(TimelineReason.designTokensUnreadable.wire == "design_tokens_unreadable")
        #expect(TimelineReason.campaignUnsupported.wire == "campaign_unsupported")
        #expect(TimelineReason.cepTriggerReceived.wire == "cep_trigger_received")
        #expect(TimelineReason.displayed.wire == "displayed")
        #expect(TimelineReason.clicked.wire == "clicked")
        #expect(TimelineReason.allCases.count == 15)
    }

    /// The delivery enums *are* the timeline's reasons for a delivery — no
    /// twin symbol, no conversion. This pins that `wire` and `value` can never
    /// drift apart.
    @Test("DropReason and DismissReason carry their pinned value as their wire")
    func deliveryEnumsAreDiagnosticReasons() {
        for reason in DropReason.allCases {
            #expect(reason.wire == reason.value)
        }
        for reason in DismissReason.allCases {
            #expect(reason.wire == reason.value)
        }
        #expect(DropReason.screenNotTargeted.wire == "screen_not_targeted")
        #expect(DismissReason.screenExit.wire == "screen_exit")
    }
}
