/// Timeline reasons that the delivery enums do not already cover.
///
/// Deliberately *not* a superset. ``DropReason`` and ``DismissReason`` are
/// pinned wire symbols the analytics backend already receives from three
/// runtimes, so a delivery's own reasons are taken from them directly and this
/// enum covers only the rest of the journey: the session, the fetch, the parse,
/// and the two positive delivery beats that are not "it ended".
///
/// The set grows additively as features land. Reserved names from the
/// vocabulary that have no emit site yet are deliberately absent rather than
/// declared early — a symbol nothing sends is a promise to a renderer that
/// nothing keeps. Four of the vocabulary's live names are missing for that
/// reason, on every stack: `plugin_missing` (needs a heuristic, not a log
/// call), `test_invocation_received` (LiveTestSink's), `action_failed` and
/// `survey_submitted` (out of the first slice).
///
/// platform note: Dart also carries `sdk_init_failed`. This core has no path
/// that can send it — `SDKInstance.initialize` absorbs a failed campaign fetch
/// and still reaches `ready`, so the honest row for that case is the
/// `fetch_failed_*` pair below. Declaring the symbol anyway would promise a
/// renderer a row that never arrives.
enum TimelineReason: String, CaseIterable, DiagnosticReason {
    // MARK: session

    /// `Digia.initialize()` completed.
    case sdkInitialized = "sdk_initialized"

    /// A CEP plugin attached. Which one is in `extras`.
    case pluginRegistered = "plugin_registered"

    /// The live-test stream came up.
    case liveSessionConnected = "live_session_connected"

    /// The live-test stream went down.
    case liveSessionDisconnected = "live_session_disconnected"

    // MARK: app events (Digia.trackEvent)

    /// A `Digia.trackEvent` call broke one of the app-event limits and was
    /// dropped before queueing. `extras` carries a sample `event_name`.
    case appEventInvalid = "app_event_invalid"

    /// App events were dropped by the bundle's rate or burst limit.
    case appEventRateLimited = "app_event_rate_limited"

    /// App events were dropped because their name is on the bundle's blocklist.
    case appEventBlocked = "app_event_blocked"

    /// App events were evicted because the app-event queue reached its cap.
    case appEventQueueFull = "app_event_queue_full"

    // MARK: user context

    /// The server did not verify the `userHash` sent with the user ID.
    case userHashUnverified = "user_hash_unverified"

    /// The user-context request failed. Rules use the cached copy, if any.
    case userContextFailed = "user_context_failed"

    // MARK: fetch

    /// Campaigns came down from Digia. The count is in `extras`.
    case bundleFetched = "bundle_fetched"

    /// The fetch succeeded and returned nothing. Distinct from a failure: the
    /// most common cause of "my campaign never shows" is that it is not live.
    case bundleEmpty = "bundle_empty"

    /// The campaign fetch could not reach Digia, or Digia answered badly.
    case fetchFailedNetwork = "fetch_failed_network"

    /// The campaign fetch was rejected — a wrong or expired API key.
    case fetchFailedAuth = "fetch_failed_auth"

    /// Digia answered the fetch with an error status or a body this SDK cannot read.
    case fetchFailedResponse = "fetch_failed_response"

    /// The bundle has CEP-triggered campaigns, but no CEP plugin is registered.
    case pluginNotRegistered = "plugin_not_registered"

    // MARK: parse

    /// One campaign in the bundle could not be read and was skipped. The rest
    /// of the bundle survived.
    case malformedCampaignSkipped = "malformed_campaign_skipped"

    /// A design token a campaign refers to is missing or unusable, so the
    /// authored default stands in.
    case unknownDesignToken = "unknown_design_token"

    /// The bundle's whole token catalog could not be read, stripping tokens
    /// from every campaign in it.
    case designTokensUnreadable = "design_tokens_unreadable"

    /// A campaign of a type this SDK cannot render. Kept in the store for
    /// diagnostics; it will never appear.
    case campaignUnsupported = "campaign_unsupported"

    /// A campaign authored with a schema version newer than this SDK reads.
    case schemaVersionTooNew = "schema_version_too_new"

    /// A canvas widget of a type this SDK cannot draw. The widget is skipped.
    case unsupportedWidgetType = "unsupported_widget_type"

    /// A declared variable got no CEP value and has no fallback, so it renders empty.
    case missingVariable = "missing_variable"

    /// A CTA step of a type this SDK cannot run. The step is skipped.
    case unsupportedActionType = "unsupported_action_type"

    // MARK: trigger

    /// A CEP handed us a trigger payload.
    ///
    /// It means exactly that a payload *arrived*. There is deliberately no
    /// symbol meaning "the CEP decided not to fire": that decision happens in
    /// CleverTap, WebEngage or MoEngage, outside this process, and the SDK
    /// reports only what it observed.
    case cepTriggerReceived = "cep_trigger_received"

    // MARK: rules

    /// A Digia-owned rule fired its campaign. No CEP delivered it.
    case ruleFired = "rule_fired"

    /// A Digia-owned rule needs a feature this SDK does not know.
    case unsupportedFeature = "unsupported_feature"

    /// A Digia-owned rule is not well-formed.
    case malformedRule = "malformed_rule"

    /// The signal matched a rule, but its conditions are false for this user.
    case conditionFailed = "condition_failed"

    /// The rule passed, but the user is not in the campaign's audience.
    case notInAudience = "not_in_audience"

    /// The rule passed, but the campaign's frequency cap is reached.
    case capped = "capped"

    /// Eligible, but a campaign with a higher priority won the same signal.
    /// The winner's key is in the `lost_to` extra.
    case lowerPriority = "lower_priority"

    /// A rule matched and its campaign now waits for its `delay`.
    case waitStarted = "wait_started"

    /// A wait already runs for this campaign. The first timer stays.
    case waitInProgress = "wait_in_progress"

    /// A pending wait ended without a show. The cause is in `extras`.
    case waitCancelled = "wait_cancelled"

    /// A wait ran its full time. The campaign is checked again, then routed.
    case waitEnded = "wait_ended"

    // MARK: render

    /// The experience reached the screen.
    case displayed = "displayed"

    /// Campaign media could not load (4xx, invalid URL, or undecodable).
    case mediaLoadFailed = "media_load_failed"

    // MARK: interaction

    /// The user tapped it. Which element is in `extras`.
    case clicked = "clicked"

    /// A custom-KV CTA ran with no host handler set.
    case actionHandlerMissing = "action_handler_missing"

    /// The survey answers could not be posted; Digia rejected them.
    case surveySubmissionFailed = "survey_submission_failed"

    /// The pinned string form. Never derive this from the case name.
    var wire: String { rawValue }
}

/// Reasons a CEP plugin logs about its own CEP SDK. Public because plugins live in other modules.
public enum CEPPluginReason: String, CaseIterable, DiagnosticReason {
    /// A private CEP API the plugin needs is missing, often after a CEP SDK upgrade.
    case bridgeUnavailable = "cep_bridge_unavailable"

    public var wire: String { rawValue }
}
