/// Which driver asked the SDK to show a campaign.
enum CampaignSourceKind {
    case cep, liveTest, digia, host
}

/// The ways the drivers differ, as one object.
///
/// The gates read these rather than asking what kind of driver they hold, so
/// "a live test skips the cap" is a field here, not an `if` inside a gate.
struct SourcePolicy {
    /// Whether the frequency gate applies. A live test always shows.
    let respectsFrequencyCaps: Bool

    /// Reports a gate's drop to whoever asked. Only a live test acts on it,
    /// posting `failed` to its dashboard row.
    let onDropped: @MainActor (DiagnosticReason, String?) -> Void

    @MainActor static func unreported(_ code: DiagnosticReason, _ detail: String?) {}
}

/// Something that asks the SDK to show a campaign.
///
/// The driver is the whole of the difference between the sources; routing reads
/// ``policy`` and ``owner`` and never asks which driver it holds. The one
/// exception is the surface gate's live-test path.
protocol CampaignDriver {
    var kind: CampaignSourceKind { get }
    var policy: SourcePolicy { get }

    /// The owner a routed campaign's presentation settles under: the CEP plugin,
    /// whose slot a settle releases, or ``CampaignDriverOwner/digia``, which
    /// releases nothing.
    var owner: String { get }
}

enum CampaignDriverOwner {
    static let digia = "digia"
}

/// The CEP plugin driver: caps apply, and the plugin holds its display slot
/// until the presentation settles.
struct CepDriver: CampaignDriver {
    let pluginId: String
    var kind: CampaignSourceKind { .cep }
    var policy: SourcePolicy {
        SourcePolicy(respectsFrequencyCaps: true, onDropped: SourcePolicy.unreported)
    }
    var owner: String { pluginId }
}

/// A dashboard live test: skips the cap, holds no slot, and reports every
/// verdict to its own row.
struct LiveTestDriver: CampaignDriver {
    let context: LiveTestContext
    var kind: CampaignSourceKind { .liveTest }
    var policy: SourcePolicy {
        SourcePolicy(
            respectsFrequencyCaps: false,
            onDropped: { [context] code, detail in context.reportFailed(code, message: detail) })
    }
    var owner: String { CampaignDriverOwner.digia }
}

/// Digia's own rule engine: its winner routes like any other campaign, but no
/// CEP holds a slot for it.
struct DigiaDriver: CampaignDriver {
    var kind: CampaignSourceKind { .digia }
    var policy: SourcePolicy {
        SourcePolicy(respectsFrequencyCaps: true, onDropped: SourcePolicy.unreported)
    }
    var owner: String { CampaignDriverOwner.digia }
}

/// The host app asking for a campaign by key, with no CEP involved: like
/// ``DigiaDriver`` it holds no slot, so caps apply and a drop goes unreported.
struct HostDriver: CampaignDriver {
    var kind: CampaignSourceKind { .host }
    var policy: SourcePolicy {
        SourcePolicy(respectsFrequencyCaps: true, onDropped: SourcePolicy.unreported)
    }
    var owner: String { CampaignDriverOwner.digia }
}
