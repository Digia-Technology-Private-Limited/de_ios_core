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
        #expect(TimelineReason.schemaVersionTooNew.wire == "schema_version_too_new")
        #expect(TimelineReason.unsupportedWidgetType.wire == "unsupported_widget_type")
        #expect(TimelineReason.missingVariable.wire == "missing_variable")
        #expect(TimelineReason.cepTriggerReceived.wire == "cep_trigger_received")
        #expect(TimelineReason.displayed.wire == "displayed")
        #expect(TimelineReason.clicked.wire == "clicked")
        #expect(TimelineReason.fetchFailedResponse.wire == "fetch_failed_response")
        #expect(TimelineReason.pluginNotRegistered.wire == "plugin_not_registered")
        #expect(TimelineReason.unsupportedActionType.wire == "unsupported_action_type")
        #expect(TimelineReason.mediaLoadFailed.wire == "media_load_failed")
        #expect(TimelineReason.actionHandlerMissing.wire == "action_handler_missing")
        #expect(TimelineReason.surveySubmissionFailed.wire == "survey_submission_failed")
        #expect(CEPPluginReason.bridgeUnavailable.wire == "cep_bridge_unavailable")
        #expect(TimelineReason.allCases.count == 24)
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

    /// `HealthReasons` is part of the wire contract with the Digia backend —
    /// reviewed like one — so every string is spelled out longhand here too.
    @Test("HealthReasons allowlist wires")
    func healthReasonsWires() {
        #expect(
            HealthReasons.reasons == [
                "unknown_campaign_key",
                "malformed_campaign_skipped",
                "unknown_design_token",
                "design_tokens_unreadable",
                "schema_version_too_new",
                "unsupported_widget_type",
                "campaign_unsupported",
                "fetch_failed_auth",
                "invalid_config",
                "missing_variable",
                "not_ready",
                "initialization_failed",
                "surface_busy",
                "timeout",
                "pending_expired",
                "superseded",
                "unsupported_action_type",
                "action_handler_missing",
                "fetch_failed_response",
                "plugin_not_registered",
                "survey_submission_failed",
                "media_load_failed",
                "cep_bridge_unavailable",
            ])
    }

    @Test("HealthReasons detail-key projections")
    func healthReasonsDetailKeys() {
        #expect(HealthReasons.detailKeys["timeout"] == ["surface_kind"])
        #expect(HealthReasons.detailKeys["pending_expired"] == ["cep"])
        #expect(HealthReasons.detailKeys["superseded"] == ["cep"])
        #expect(HealthReasons.detailKeys["unknown_campaign_key"] == [])
        #expect(HealthReasons.detailKeys["malformed_campaign_skipped"] == [])
        #expect(HealthReasons.detailKeys["unknown_design_token"] == ["token", "kind"])
        #expect(HealthReasons.detailKeys["design_tokens_unreadable"] == ["theme"])
        #expect(HealthReasons.detailKeys["schema_version_too_new"] == ["required", "supported"])
        #expect(HealthReasons.detailKeys["unsupported_widget_type"] == ["widget_type"])
        #expect(HealthReasons.detailKeys["campaign_unsupported"] == ["precondition", "type"])
        #expect(HealthReasons.detailKeys["fetch_failed_auth"] == ["http_status"])
        #expect(HealthReasons.detailKeys["invalid_config"] == ["cause"])
        #expect(HealthReasons.detailKeys["missing_variable"] == ["variable"])
        #expect(HealthReasons.detailKeys["not_ready"] == [])
        #expect(HealthReasons.detailKeys["initialization_failed"] == [])
        #expect(HealthReasons.detailKeys["surface_busy"] == ["blocking_campaign_key", "blocking_kind"])
        #expect(HealthReasons.detailKeys["unsupported_action_type"] == ["action_type"])
        #expect(HealthReasons.detailKeys["action_handler_missing"] == ["action_type"])
        #expect(HealthReasons.detailKeys["fetch_failed_response"] == ["http_status"])
        #expect(HealthReasons.detailKeys["plugin_not_registered"] == [])
        #expect(HealthReasons.detailKeys["survey_submission_failed"] == ["http_status"])
        #expect(HealthReasons.detailKeys["media_load_failed"] == ["media_kind", "cause"])
        #expect(HealthReasons.detailKeys["cep_bridge_unavailable"] == ["selector"])
        // Every allowlisted reason has an explicit projection, even if empty —
        // an absent entry and an empty list must never be conflated.
        for reason in HealthReasons.reasons {
            #expect(HealthReasons.detailKeys[reason] != nil, "\(reason) has no detail-key entry")
        }
    }

    @Test("HealthReasons dedup shape")
    func healthReasonsDedupShape() {
        #expect(HealthReasons.campaignlessReasons == [
            "design_tokens_unreadable", "fetch_failed_auth", "fetch_failed_response",
            "plugin_not_registered",
        ])
        #expect(HealthReasons.dedupExtraKeys == [
            "unknown_design_token": ["token"],
            "missing_variable": ["variable"],
            "unsupported_widget_type": ["widget_type"],
            "invalid_config": ["cause"],
            "surface_busy": ["blocking_campaign_key"],
            "unsupported_action_type": ["action_type"],
            "action_handler_missing": ["action_type"],
            "cep_bridge_unavailable": ["selector"],
            "media_load_failed": ["media_kind", "cause"],
        ])
        #expect(HealthReasons.liveTestBlockerKey == "blocking_live_test")
    }
}
