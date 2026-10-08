import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

struct CampaignBundle {
    let rawCampaigns: [[String: Any]]
    let designTokens: DesignTokenCatalog
    let timeAnchor: TrustedTimeAnchor?
    let campaigns: [CampaignModel]

    /// The server's health-telemetry kill switch for this session (`sdkHealth`
    /// on the wire). Defaults to on, so a backend that has not shipped the
    /// flag behaves exactly as one that shipped it set to true — see
    /// sdk-health-telemetry.md §5.
    let healthEnabled: Bool

    /// The server's per-session health-event cap (`sdkHealthSessionCap` on the
    /// wire), or `nil` to use ``HealthSink/defaultSessionCap``.
    let healthSessionCap: Int?

    // platform note: unlike Flutter's `CampaignBundle`, which defers
    // per-campaign parsing to a lazy `.parse()` called after the health
    // config above is applied, this initializer parses every campaign (and
    // therefore fires every parse-stage health reason) synchronously, before
    // the caller can ever read `healthEnabled`/`healthSessionCap` back off the
    // return value. On this core, a first bundle whose parse trips
    // `malformed_campaign_skipped` / `unknown_design_token` /
    // `campaign_unsupported` reports those events under the SDK's defaults
    // (switch on, cap 20) even when the server's response — read moments
    // later — says otherwise, not just `design_tokens_unreadable` as the spec
    // describes for Flutter. Restructuring this into a two-phase parse to
    // close that gap is out of scope here; flagged for a follow-up.
    static func create(
        rawCampaigns: [[String: Any]],
        designTokensJSON: [String: Any]?,
        devicePlatform: String? = nil,
        serverTimeMs: Int64? = nil,
        healthEnabled: Bool = true,
        healthSessionCap: Int? = nil
    ) -> CampaignBundle {
        let catalog: DesignTokenCatalog
        do { catalog = try designTokensJSON.map(DesignTokenCatalog.fromJson) ?? .empty }
        catch {
            log.e(
                "Design tokens unreadable — falling back to literal values",
                error: error.localizedDescription,
                stage: .parse,
                reason: TimelineReason.designTokensUnreadable
            )
            catalog = .empty
        }
        let timeAnchor = TrustedTimeAnchor.capture(serverTimeMs)
        let campaigns = rawCampaigns.enumerated().compactMap { index, json -> CampaignModel? in
            let scope = CampaignParseScope(campaignKey: json["campaignKey"] as? String)
            let parsed: CampaignModel?
            do {
                parsed = try CampaignParseScope.$current.withValue(scope) {
                    try CampaignModel.fromJson(
                        json,
                        designTokens: catalog,
                        devicePlatform: devicePlatform,
                        timeAnchor: timeAnchor
                    )
                }
            } catch is ReportedParseFailure {
                // A nested parser already said why; a second report would count it twice.
                return nil
            } catch {
                parsed = nil
            }
            if let parsed { return parsed }
            log.e(
                "Campaign skipped — could not be read (index=\(index))",
                campaign: scope.campaignKey,
                stage: .parse,
                reason: TimelineReason.malformedCampaignSkipped
            )
            return nil
        }
        return CampaignBundle(
            rawCampaigns: rawCampaigns,
            designTokens: catalog,
            timeAnchor: timeAnchor,
            campaigns: campaigns,
            healthEnabled: healthEnabled,
            healthSessionCap: healthSessionCap
        )
    }
}

/// The campaign being parsed, so a nested parser can name it in a report.
final class CampaignParseScope: Sendable {
    @TaskLocal static var current: CampaignParseScope?

    let campaignKey: String?

    init(campaignKey: String?) {
        self.campaignKey = campaignKey
    }

    /// Logs a parse-stage record for the current campaign, and returns the error that ends its parse.
    static func report(
        _ message: String, reason: DiagnosticReason, extras: [String: String]? = nil
    ) -> ReportedParseFailure {
        log.e(message, campaign: current?.campaignKey, stage: .parse, reason: reason, extras: extras)
        return ReportedParseFailure()
    }

    /// Whether `version` is readable. A newer version is reported and thrown; an older one
    /// is left to the caller's `malformed_campaign_skipped`.
    static func acceptsVersion(_ version: Int, supported: Int) throws -> Bool {
        if version > supported {
            throw report(
                "Campaign skipped — schema version \(version) is newer than \(supported)",
                reason: TimelineReason.schemaVersionTooNew,
                extras: ["required": String(version), "supported": String(supported)]
            )
        }
        return version == supported
    }
}

/// A campaign parse failure that already sent its own health record.
struct ReportedParseFailure: Error {}

/// Runs `body`; a `ReportedParseFailure` passes through, and any other error gives nil.
func parseOrNil<T>(_ body: () throws -> T?) throws -> T? {
    do { return try body() } catch let reported as ReportedParseFailure { throw reported } catch { return nil }
}
