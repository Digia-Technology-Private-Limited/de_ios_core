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
    /// ten have no emit site on this core yet, and the rest are spread across
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
        "design_tokens_unreadable": [],
        "schema_version_too_new": ["required", "supported"],
        "unsupported_widget_type": ["widget_type"],
        "campaign_unsupported": ["precondition", "type"],
        "fetch_failed_auth": ["http_status"],
        "invalid_config": [],
        "missing_variable": [],
    ]

    /// Reasons that identify *no* campaign, and so dedup on the symbol alone.
    ///
    /// Both are bundle-wide facts: the fetch was rejected, or the whole token
    /// catalog was unreadable. Keying them on a campaign would report one per
    /// campaign for a failure that happened once.
    static let campaignlessReasons: Set<String> = [
        "design_tokens_unreadable",
        "fetch_failed_auth",
    ]

    /// The extra that makes one campaign's several instances of a reason
    /// distinct.
    ///
    /// Spec §2's dedup key is `(reason, campaign)` for eight of the ten. The
    /// two here can happen repeatedly within one campaign for genuinely
    /// different causes — two broken tokens, two unsupplied variables — and
    /// collapsing them would report the first and hide the rest, which is the
    /// opposite of what the backend is being asked.
    static let dedupExtraKey: [String: String] = [
        "unknown_design_token": "token",
        "missing_variable": "variable",
    ]
}
