import SwiftUI

/// "I set up my campaign and used the app — what happened?"
///
/// The audience is a campaign creator — a PM, a marketer, someone in Customer
/// Success — not a developer. So this screen renders the *same records* the
/// console does, in their words: no severities, no enum names, no ids unless
/// they are the only handle on something.
///
/// Two shapes, because the records have two shapes. Anything carrying a
/// `presentationId` is one showing of one campaign and groups into a card —
/// delivered, displayed, clicked, dismissed, in the order it happened.
/// Everything else (the SDK started, campaigns came down, one could not be
/// read) is a flat row. Newest first either way, because the thing that just
/// happened is the reason the screen was opened.
///
/// **Unrecognised symbols render raw.** The vocabulary grows as features land,
/// and a renderer that drops or throws on a symbol it does not know is a
/// renderer that hides exactly the new thing someone is trying to debug. The
/// raw `snake_case` is ugly and completely usable.
///
/// platform note: Dart's twin is `DigiaCampaignTimelineScreen`.
@MainActor
struct DigiaCampaignTimelineView: View {
    @ObservedObject private var timeline = ScreenSink.shared

    var body: some View {
        // `revision` is read so the view depends on it explicitly — the sink
        // bumps it on the next main-queue turn after a record lands, never
        // inline, so nothing here can be asked to rebuild mid-frame.
        let entries = TimelineEntry.group(timeline.snapshot(), revision: timeline.revision)
        return Group {
            if entries.isEmpty {
                emptyState
            } else {
                List(entries) { entry in
                    if entry.isDelivery {
                        deliveryCard(entry.records)
                    } else if let record = entry.records.first {
                        flatRow(record)
                    }
                }
            }
        }
        .navigationTitle("Campaign timeline")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text(
                "Nothing recorded yet.\n\nUse the app as a user would. Anything Digia does "
                    + "with a campaign shows up here."
            )
            .multilineTextAlignment(.center)
            .foregroundColor(.secondary)
            .padding(32)
            Spacer()
        }
    }

    /// One showing of one campaign, its beats in the order they happened.
    private func deliveryCard(_ records: [TimelineRecord]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(records.first?.campaignKey ?? "Campaign")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(Self.clock(records.first?.timestamp ?? Date()))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                HStack(alignment: .top, spacing: 10) {
                    dot(record.severity)
                    Text(Self.sentence(record))
                        .font(.footnote)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// A record that belongs to no delivery — the session, the fetch, a parse.
    private func flatRow(_ record: TimelineRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            dot(record.severity)
            Text(Self.sentence(record))
                .font(.footnote)
            Spacer(minLength: 0)
            Text(Self.clock(record.timestamp))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Severity as a colour, read before it is read as a word.
    private func dot(_ severity: DigiaLogSeverity) -> some View {
        Circle()
            .fill(Self.color(severity))
            .frame(width: 8, height: 8)
            .padding(.top, 5)
    }

    private static func color(_ severity: DigiaLogSeverity) -> Color {
        switch severity {
        case .error: return Color(red: 0.827, green: 0.184, blue: 0.184)
        case .warn: return Color(red: 0.976, green: 0.659, blue: 0.145)
        case .info: return Color(red: 0.098, green: 0.463, blue: 0.824)
        case .debug: return Color(red: 0.620, green: 0.620, blue: 0.620)
        }
    }

    /// Wall-clock `HH:MM:SS`. No date: the buffer dies with the process, so
    /// everything in it happened in this session.
    private static func clock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// What a record says, in a campaign creator's words.
    ///
    /// Falls through to the raw symbol, then to the developer message, so every
    /// record renders as *something* — see the forward-compatibility rule on
    /// this type.
    static func sentence(_ record: TimelineRecord) -> String {
        guard let wire = record.reason?.wire else { return record.message }
        guard let copy = copy[wire] else { return wire }
        guard let detail = detail(wire, record) else { return copy }
        return "\(copy) \(detail)"
    }

    /// The one piece of `extras` worth putting in front of a non-developer, per
    /// reason. Everything else in `extras` is for a developer reading the
    /// console.
    private static func detail(_ wire: String, _ record: TimelineRecord) -> String? {
        switch wire {
        case "clicked": return record.extras["elementId"].map { "\"\($0)\"" }
        case "bundle_fetched": return record.extras["count"].map { "(\($0))" }
        case "campaign_unsupported": return record.extras["type"].map { "(\($0))" }
        case "unknown_design_token": return record.extras["token"].map { "(\($0))" }
        case "plugin_registered": return record.extras["plugin"].map { "(\($0))" }
        default: return nil
        }
    }

    /// Symbol → sentence. The SDK sends symbols; **the renderer owns the copy**
    /// — which is what lets this wording be fixed without an SDK release, and
    /// what keeps the same symbols readable in a dashboard that words them
    /// differently.
    private static let copy: [String: String] = [
        // session
        "sdk_initialized": "Digia started",
        "plugin_registered": "Connected to your messaging platform",
        "live_session_connected": "Live testing connected",
        "live_session_disconnected": "Live testing disconnected",
        // fetch
        "bundle_fetched": "Campaigns downloaded",
        "bundle_empty": "No campaigns are live right now",
        "fetch_failed_network": "Couldn't reach Digia",
        "fetch_failed_auth": "Digia rejected this app's API key",
        // parse
        "malformed_campaign_skipped": "A campaign couldn't be read and was skipped",
        "unknown_design_token": "A design token is missing — using the authored value",
        "design_tokens_unreadable": "This app's design tokens couldn't be read",
        "campaign_unsupported": "This campaign type can't show in this app",
        // trigger
        "cep_trigger_received": "Delivered",
        "not_initialized": "Not shown — Digia wasn't ready yet",
        "not_ready": "Not shown — campaigns were still loading",
        "initialization_failed": "Not shown — campaigns couldn't be loaded",
        "unknown_campaign_key": "Not shown — no campaign with this key",
        // gating
        "frequency_capped": "Not shown — frequency cap reached",
        "screen_not_targeted": "Not shown — not one of this campaign's screens",
        "surface_busy": "Not shown — something else was already on screen",
        // render
        "displayed": "Displayed",
        "invalid_config": "Not shown — the campaign's setup couldn't be read",
        "anchor_not_registered": "Not shown — the element it points at isn't on this screen",
        "host_not_mounted": "Not shown — this screen has no Digia host",
        "timeout": "Not shown — it never appeared in time",
        "error": "Not shown — something went wrong",
        // interaction
        "clicked": "Clicked",
        "user_close": "Dismissed — closed",
        "scrim_tap": "Dismissed — tapped outside",
        "back_gesture": "Dismissed — back gesture",
        "cta_action": "Dismissed — a button closed it",
        "auto_timeout": "Dismissed — closed itself",
        "screen_exit": "Dismissed — left the screen",
        "completed": "Finished",
        // Shared by the drop and dismiss arms: the same word is correct whether
        // it was replaced before or after it appeared.
        "superseded": "Replaced by a newer campaign",
        "cancelled": "Cancelled",
        "plugin_detached": "Your messaging platform was disconnected",
    ]
}

/// One row of the timeline list: a delivery card, or a single flat record.
struct TimelineEntry: Identifiable {
    let id: String
    let records: [TimelineRecord]
    let isDelivery: Bool

    /// Buckets a newest-first snapshot into delivery cards and flat rows.
    ///
    /// A delivery keeps the position of its most recent record — so a campaign
    /// that was just dismissed rises to the top — while the rows *inside* it
    /// read oldest-first, because a card is a story and a story has an order.
    ///
    /// `revision` only participates in the row ids, so SwiftUI rebuilds the
    /// list rather than reusing rows across two different snapshots.
    static func group(_ newestFirst: [TimelineRecord], revision: Int = 0) -> [TimelineEntry] {
        var entries: [TimelineEntry] = []
        var cardIndex: [String: Int] = [:]
        for (position, record) in newestFirst.enumerated() {
            guard let presentationId = record.presentationId else {
                entries.append(
                    TimelineEntry(
                        id: "flat-\(revision)-\(position)", records: [record], isDelivery: false))
                continue
            }
            if let existing = cardIndex[presentationId] {
                entries[existing] = TimelineEntry(
                    id: entries[existing].id,
                    records: [record] + entries[existing].records,
                    isDelivery: true
                )
                continue
            }
            cardIndex[presentationId] = entries.count
            entries.append(
                TimelineEntry(
                    id: "delivery-\(revision)-\(presentationId)", records: [record], isDelivery: true))
        }
        return entries
    }
}
