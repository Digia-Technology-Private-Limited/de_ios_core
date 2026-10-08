import Foundation

/// The Digia-owned allowlist of reasons that may leave the device.
///
/// Named `HEALTH_REASONS` in
/// [the spec](../../../../../../ai_docs/sdk-health-telemetry.md) §2; this type is
/// the Swift spelling. It is **part of the wire contract** — changes are
/// reviewed like one, and the spec's table is the source of truth.
///
/// Three rules this type exists to enforce, all of them structural rather than
/// remembered:
///
/// - **Routing is central, never per call site.** A call site fills in a
///   ``DiagnosticReason``; nothing it can write opts itself into the uplink.
///   Adding a symbol here is the only way in, which is why this list sits
///   apart from ``HealthSink`` rather than inside it.
/// - **Only named keys reach the wire.** ``detailKeys`` is the whole of what a
///   reason may carry as `detail`; every other extra is dropped. A free-text
///   value therefore cannot reach the backend by any path, because no path
///   carries it.
/// - **A symbol with no emit site is fine.** Several entries here are dormant:
///   this core never emits them yet. The list is additive and central, so
///   each goes live the day its emit site lands, with no change to this type.
enum HealthReasons {
    /// Reasons the backend may hear about, by wire symbol.
    ///
    /// Wire strings rather than a closed Swift enum on purpose: three of the
    /// twelve have no emit site on this core yet, and the rest are spread across
    /// ``DropReason`` and `TimelineReason` — two enums that deliberately do not
    /// merge. Matching on ``DiagnosticReason/wire`` is the one thing all of
    /// them share.
    static let reasons: Set<String> = [
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
        // Startup drops (SP5/SP6): a trigger that reached core before the SDK
        // was ready. `not_initialized` stays off the list — the sink does not
        // exist before `initialize()`.
        "not_ready",
        "initialization_failed",
        // A setup mistake the customer fixes, not breakage (surface rule §2.5):
        // one campaign turned away by another that holds the surface.
        "surface_busy",
        // Breakage (R3-D10): an accepted campaign nothing drew within the
        // acceptance window. Only the organic acceptance watchdog emits it as a
        // drop record; a live test's timeout is an ACK, never a record.
        "timeout",
        // A CEP plugin's pending buffer (#71): held too long, or pushed out when full.
        "pending_expired",
        "superseded",
        "unsupported_action_type",
        "action_handler_missing",
        "fetch_failed_response",
        "plugin_not_registered",
        "survey_submission_failed",
        "media_load_failed",
        "cep_bridge_unavailable",
    ]

    /// Which `extras` keys each reason may send as `detail` — and nothing else.
    ///
    /// The spec's `detail` column, widened in two places where the live emit
    /// site already carries something the spec's author had not seen (decided
    /// 2026-09-19 during the Flutter build, recorded back into spec §2):
    ///
    /// - `unknown_design_token` also sends `kind` (`color` / `typography`),
    ///   which separates a broken palette from a broken type scale without a
    ///   second query.
    /// - `campaign_unsupported` also sends `type`. The spec describes this
    ///   symbol as an unhonourable *runtime precondition* and names
    ///   `precondition`; this core's one live emit site
    ///   (`CampaignModel.fromJson`, an unparseable stateful-timer config) sends
    ///   `type`. Both keys are listed rather than one guessed at — see the
    ///   note in spec §2 about the two readings.
    ///
    /// A reason absent from this map sends no `detail` at all. A reason
    /// present with an empty list is the same thing said explicitly, so that
    /// adding a key later is a visible edit here rather than a new entry
    /// nobody reviews.
    static let detailKeys: [String: [String]] = [
        "unknown_campaign_key": [],
        "malformed_campaign_skipped": [],
        "unknown_design_token": ["token", "kind"],
        "design_tokens_unreadable": ["theme"],
        "schema_version_too_new": ["required", "supported"],
        "unsupported_widget_type": ["widget_type"],
        "campaign_unsupported": ["precondition", "type"],
        "fetch_failed_auth": ["http_status"],
        "invalid_config": ["cause"],
        "missing_variable": ["variable"],
        "not_ready": [],
        "initialization_failed": [],
        "surface_busy": ["blocking_campaign_key", "blocking_kind"],
        "timeout": ["surface_kind"],
        "pending_expired": ["cep"],
        "superseded": ["cep"],
        "unsupported_action_type": ["action_type"],
        "action_handler_missing": ["action_type"],
        "fetch_failed_response": ["http_status"],
        "plugin_not_registered": [],
        "survey_submission_failed": ["http_status"],
        "media_load_failed": ["media_kind", "cause"],
        "cep_bridge_unavailable": ["selector"],
    ]

    /// Reasons that identify *no* campaign, and so dedup on the symbol alone.
    ///
    /// Each is an app-wide fact: a failed fetch, an unreadable token catalog,
    /// or a host setup gap. Keying them on a campaign would report one per
    /// campaign for a failure that happened once.
    static let campaignlessReasons: Set<String> = [
        "design_tokens_unreadable",
        "fetch_failed_auth",
        "fetch_failed_response",
        "plugin_not_registered",
    ]

    /// The extra that makes one campaign's several instances of a reason
    /// distinct.
    ///
    /// Spec §2's dedup key is `(reason, campaign)` for ten of the twelve. The
    /// two here can happen repeatedly within one campaign for genuinely
    /// different causes — two broken tokens, two unsupplied variables — and
    /// collapsing them would report the first and hide the rest, which is the
    /// opposite of what the backend is being asked.
    static let dedupExtraKeys: [String: [String]] = [
        "unknown_design_token": ["token"],
        "missing_variable": ["variable"],
        "unsupported_widget_type": ["widget_type"],
        // A fixed token per failed precondition, so two causes stay two reports.
        "invalid_config": ["cause"],
        // One report per (dropped campaign, blocker) per launch — "blocked by X
        // on N% of app opens".
        "surface_busy": ["blocking_campaign_key"],
        "unsupported_action_type": ["action_type"],
        "action_handler_missing": ["action_type"],
        "cep_bridge_unavailable": ["selector"],
        "media_load_failed": ["media_kind", "cause"],
    ]

    /// Extra marking a record whose blocker is a live test. Such a record stays
    /// on the console and timeline but never reaches HealthSink: a PM's testing
    /// must not show up in the customer's report (§2.5, LT-Q2).
    static let liveTestBlockerKey = "blocking_live_test"

    /// The timeline extras for a `surface_busy` drop.
    static func surfaceBusyExtras(
        blockingCampaignKey: String, blockingKind: String, blockerIsLiveTest: Bool
    ) -> [String: String] {
        var extras = [
            "blocking_campaign_key": blockingCampaignKey,
            "blocking_kind": blockingKind,
        ]
        if blockerIsLiveTest { extras[liveTestBlockerKey] = "true" }
        return extras
    }
}
