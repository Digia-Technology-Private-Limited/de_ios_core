import Foundation

/// What a campaign occupies on screen, for the surface rule.
///
/// See `ai_docs/surface-rule-plan.md` §2.1. The same six kinds exist on the
/// Kotlin and Dart cores, and `wire` is the `blocking_kind` value HealthSink
/// sends for a `surface_busy` drop (§2.5).
enum SurfaceKind: Equatable {
    case nudge
    case survey
    case guide
    case floaterExpanded
    case floaterCollapsed
    case inline(slot: String)

    /// Blocking kinds own the screen; the rest share it.
    var isBlocking: Bool {
        switch self {
        case .nudge, .survey, .guide, .floaterExpanded: return true
        case .floaterCollapsed, .inline: return false
        }
    }

    /// The pinned `blocking_kind` string.
    var wire: String {
        switch self {
        case .nudge: return "nudge"
        case .survey: return "survey"
        case .guide: return "guide"
        case .floaterExpanded: return "floater_expanded"
        case .floaterCollapsed: return "floater_collapsed"
        case .inline: return "inline"
        }
    }
}

/// A campaign routing accepted that has not settled yet, drawn or not.
struct SurfaceOccupant: Equatable {
    let kind: SurfaceKind
    let campaignKey: String
    let cepCampaignId: String
    let isLiveTest: Bool
    /// Whether it recorded an impression. Only read for an inline slot (SR05).
    let hasDisplayed: Bool
}

/// The rule's answer for one arriving campaign.
enum SurfaceDecision: Equatable {
    case show
    /// Drop the arrival `surface_busy`; `blocker` is the occupant the cell names.
    case busy(blocker: SurfaceOccupant)
    /// Inline, same slot, occupant never displayed: settle it `superseded` and
    /// give the slot to the arrival.
    case replace(SurfaceOccupant)
}

/// The surface rule (`ai_docs/surface-rule-plan.md` §2.1, §2.2) as data and two
/// pure functions. Identical on all three cores; change the table only with the
/// plan.
enum SurfaceRule {
    enum Cell: Equatable {
        case show
        case busy
        /// Inline over inline in the same slot (SR05).
        case sameSlot
    }

    enum Row: CaseIterable {
        case nudge, survey, guide, floater, inline
    }

    /// Ordered by precedence: with several occupants, the first busy column is
    /// the one reported (§2.5 — a floater over a nudge plus a collapsed floater
    /// names the nudge).
    enum Column: CaseIterable {
        case nothing, nudge, survey, guide, floaterExpanded, floaterCollapsed
        case inlineSameSlot, inlineOtherSlot
    }

    /// §2.1, row = arriving, column = occupant.
    static let table: [Row: [Column: Cell]] = [
        .nudge: [
            .nothing: .show, .nudge: .busy, .survey: .busy, .guide: .busy,
            .floaterExpanded: .busy, .floaterCollapsed: .show,
            .inlineSameSlot: .show, .inlineOtherSlot: .show,
        ],
        .survey: [
            .nothing: .show, .nudge: .busy, .survey: .busy, .guide: .busy,
            .floaterExpanded: .busy, .floaterCollapsed: .show,
            .inlineSameSlot: .show, .inlineOtherSlot: .show,
        ],
        .guide: [
            .nothing: .show, .nudge: .busy, .survey: .busy, .guide: .busy,
            .floaterExpanded: .busy, .floaterCollapsed: .show,
            .inlineSameSlot: .show, .inlineOtherSlot: .show,
        ],
        .floater: [
            .nothing: .show, .nudge: .busy, .survey: .busy, .guide: .busy,
            .floaterExpanded: .busy, .floaterCollapsed: .busy,
            .inlineSameSlot: .show, .inlineOtherSlot: .show,
        ],
        .inline: [
            .nothing: .show, .nudge: .show, .survey: .show, .guide: .show,
            .floaterExpanded: .show, .floaterCollapsed: .show,
            .inlineSameSlot: .sameSlot, .inlineOtherSlot: .show,
        ],
    ]

    static func row(_ incoming: SurfaceKind) -> Row {
        switch incoming {
        case .nudge: return .nudge
        case .survey: return .survey
        case .guide: return .guide
        case .floaterExpanded, .floaterCollapsed: return .floater
        case .inline: return .inline
        }
    }

    static func column(_ occupant: SurfaceKind, incoming: SurfaceKind) -> Column {
        switch occupant {
        case .nudge: return .nudge
        case .survey: return .survey
        case .guide: return .guide
        case .floaterExpanded: return .floaterExpanded
        case .floaterCollapsed: return .floaterCollapsed
        case .inline(let slot):
            if case .inline(let incomingSlot) = incoming, incomingSlot == slot {
                return .inlineSameSlot
            }
            return .inlineOtherSlot
        }
    }

    /// Total: a missing entry reads as `show`, never a crash.
    static func cell(_ incoming: SurfaceKind, _ occupant: SurfaceKind) -> Cell {
        table[row(incoming)]?[column(occupant, incoming: incoming)] ?? .show
    }

    /// Organic routing (§2.1). A real campaign never displaces a live test, so a
    /// same-slot inline test is `busy` even before it displayed (LT-Q2).
    static func decide(_ incoming: SurfaceKind, occupants: [SurfaceOccupant]) -> SurfaceDecision {
        var replace: SurfaceOccupant?
        for occupant in byPrecedence(occupants, incoming: incoming) {
            switch cell(incoming, occupant.kind) {
            case .show:
                continue
            case .busy:
                return .busy(blocker: occupant)
            case .sameSlot:
                if occupant.hasDisplayed || occupant.isLiveTest {
                    return .busy(blocker: occupant)
                }
                if replace == nil { replace = occupant }
            }
        }
        return replace.map { .replace($0) } ?? .show
    }

    /// Live test (§2.2): the test always shows, and every occupant whose cell is
    /// not `show` is displaced — a blocking one, a collapsed floater under a
    /// floater test, or the slot's occupant under an inline test, displayed or
    /// not.
    static func liveTestDisplaced(
        _ incoming: SurfaceKind, occupants: [SurfaceOccupant]
    ) -> [SurfaceOccupant] {
        byPrecedence(occupants, incoming: incoming).filter { cell(incoming, $0.kind) != .show }
    }

    private static func byPrecedence(
        _ occupants: [SurfaceOccupant], incoming: SurfaceKind
    ) -> [SurfaceOccupant] {
        let order = Column.allCases
        func rank(_ occupant: SurfaceOccupant) -> Int {
            order.firstIndex(of: column(occupant.kind, incoming: incoming)) ?? order.count
        }
        return occupants.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }
}
