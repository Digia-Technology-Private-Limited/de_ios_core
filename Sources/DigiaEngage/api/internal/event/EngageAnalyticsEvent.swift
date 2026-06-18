import Foundation

// Ported 1:1 from Android `internal/event/EngageAnalyticsEvent.kt`. The rich,
// campaign-grouped first-party (Digia analytics) event matrix. These are
// Digia-only: CEP forwarding uses the coarse `DigiaExperienceEvent` on a
// separate channel — the two concerns are deliberately not unified.

/// How a host-app surfaced a campaign. Serialized as lower_snake_case.
enum TriggerType: String {
    case event
    case screenView = "screen_view"
    case manual
    case appOpen = "app_open"

    var wire: String { rawValue }
}

/// Trigger attribution shared by every campaign's "Viewed" event.
struct TriggerContext: Equatable {
    let type: TriggerType
    let event: String?

    init(type: TriggerType, event: String? = nil) {
        self.type = type
        self.event = event
    }

    func asProperties() -> [String: Any] {
        nonNull([
            ("trigger_type", type.wire),
            ("trigger_event", event),
        ])
    }
}

/// A first-party (Digia analytics) event, modelled 1:1 on the Engage event matrix.
///
/// Events are grouped by campaign type — `NudgeEvent`, `GuideEvent`,
/// `SurveyEvent`, `CarouselEvent`, `StoriesEvent` — so each subtype exposes
/// *exactly* the fields its matrix row defines. Each leaf owns its wire
/// `eventName` and its `properties` payload (the analytics service flattens
/// `properties` under the wire `properties` key).
protocol EngageAnalyticsEvent {
    var eventName: String { get }
    var properties: [String: Any] { get }
}

extension EngageAnalyticsEvent {
    var properties: [String: Any] { [:] }
}

// ── Nudge (bottom_sheet / dialog; distinguished by displayStyle) ─────────────

enum NudgeEvent {
    struct Viewed: EngageAnalyticsEvent {
        let displayStyle: String
        var trigger: TriggerContext?
        var screenName: String?

        var eventName: String { "Digia Experience Viewed" }
        var properties: [String: Any] {
            nonNull([
                ("display_style", displayStyle),
                ("screen_name", screenName),
            ]).merging(trigger.orEmpty()) { current, _ in current }
        }
    }

    struct Clicked: EngageAnalyticsEvent {
        var elementId: String?
        var ctaLabel: String?
        var actionType: String?
        var actionUrl: String?
        var ctaRole: String?
        var timeToActionMs: Int64?

        var eventName: String { "Digia Experience Clicked" }
        var properties: [String: Any] {
            nonNull([
                ("element_id", elementId),
                ("cta_label", ctaLabel),
                ("action_type", actionType),
                ("action_url", actionUrl),
                ("cta_role", ctaRole),
                ("time_to_action_ms", timeToActionMs),
            ])
        }
    }

    struct Dismissed: EngageAnalyticsEvent {
        var dwellMs: Int64?

        var eventName: String { "Digia Experience Dismissed" }
        var properties: [String: Any] { nonNull([("dwell_ms", dwellMs)]) }
    }
}

// ── Guide (tooltip / spotlight; distinguished by displayStyle) ───────────────

enum GuideEvent {
    struct Viewed: EngageAnalyticsEvent {
        let displayStyle: String
        let itemTotal: Int
        var trigger: TriggerContext?
        var screenName: String?

        var eventName: String { "Digia Experience Viewed" }
        var properties: [String: Any] {
            nonNull([
                ("display_style", displayStyle),
                ("item_total", itemTotal),
                ("screen_name", screenName),
            ]).merging(trigger.orEmpty()) { current, _ in current }
        }
    }

    struct StepViewed: EngageAnalyticsEvent {
        let itemIndex: Int
        let itemTotal: Int
        var anchorKey: String?
        var displayStyle: String?

        var eventName: String { "Digia Step Viewed" }
        var properties: [String: Any] {
            nonNull([
                ("item_index", itemIndex),
                ("item_total", itemTotal),
                ("anchor_key", anchorKey),
                ("display_style", displayStyle),
            ])
        }
    }

    struct StepClicked: EngageAnalyticsEvent {
        let itemIndex: Int
        var elementId: String?
        var ctaLabel: String?
        var actionType: String?
        var actionUrl: String?

        var eventName: String { "Digia Step Clicked" }
        var properties: [String: Any] {
            nonNull([
                ("item_index", itemIndex),
                ("element_id", elementId),
                ("cta_label", ctaLabel),
                ("action_type", actionType),
                ("action_url", actionUrl),
            ])
        }
    }

    struct StepDismissed: EngageAnalyticsEvent {
        let itemIndex: Int

        var eventName: String { "Digia Step Dismissed" }
        var properties: [String: Any] { nonNull([("item_index", itemIndex)]) }
    }

    /// Guide abandoned (rolls up step-level dismiss).
    struct Dismissed: EngageAnalyticsEvent {
        var abandonedAtItem: Int?
        var itemTotal: Int?
        var dwellMs: Int64?

        var eventName: String { "Digia Experience Dismissed" }
        var properties: [String: Any] {
            nonNull([
                ("abandoned_at_item", abandonedAtItem),
                ("item_total", itemTotal),
                ("dwell_ms", dwellMs),
            ])
        }
    }

    struct Completed: EngageAnalyticsEvent {
        var itemTotal: Int?
        var timeToCompleteMs: Int64?

        var eventName: String { "Digia Experience Completed" }
        var properties: [String: Any] {
            nonNull([
                ("item_total", itemTotal),
                ("time_to_complete_ms", timeToCompleteMs),
            ])
        }
    }
}

// ── Survey ──────────────────────────────────────────────────────────────────

enum SurveyEvent {
    struct Viewed: EngageAnalyticsEvent {
        var itemTotal: Int?
        var hasWelcome: Bool?
        var hasThanks: Bool?
        var hasBranching: Bool?
        var trigger: TriggerContext?
        var screenName: String?

        var eventName: String { "Digia Experience Viewed" }
        var properties: [String: Any] {
            nonNull([
                ("item_total", itemTotal),
                ("has_welcome", hasWelcome),
                ("has_thanks", hasThanks),
                ("has_branching", hasBranching),
                ("screen_name", screenName),
            ]).merging(trigger.orEmpty()) { current, _ in current }
        }
    }

    /// Start tapped on the welcome screen, or first-answer engagement.
    struct Clicked: EngageAnalyticsEvent {
        var elementId: String?

        var eventName: String { "Digia Experience Clicked" }
        var properties: [String: Any] { nonNull([("element_id", elementId)]) }
    }

    struct QuestionViewed: EngageAnalyticsEvent {
        let questionId: String
        var questionTitle: String?
        var questionType: String?
        var itemIndex: Int?
        var itemTotal: Int?
        var blockType: String?
        var blockId: String?
        var isRequired: Bool?

        var eventName: String { "Digia Question Viewed" }
        var properties: [String: Any] {
            nonNull([
                ("question_id", questionId),
                ("question_title", questionTitle),
                ("question_type", questionType),
                ("item_index", itemIndex),
                ("item_total", itemTotal),
                ("block_type", blockType),
                ("block_id", blockId),
                ("is_required", isRequired),
            ])
        }
    }

    struct QuestionAnswered: EngageAnalyticsEvent {
        let questionId: String
        var questionTitle: String?
        var questionType: String?
        var answerValue: String?
        var answerText: String?
        var blockType: String?
        var blockId: String?
        var answerLabel: String?
        var answerOptions: [String]?
        var scaleMin: Int?
        var scaleMax: Int?
        var timeToAnswerMs: Int64?
        var answer: [String: Any] = [:]

        var eventName: String { "Digia Question Answered" }
        var properties: [String: Any] {
            nonNull([
                ("question_id", questionId),
                ("question_title", questionTitle),
                ("question_type", questionType),
                ("answer_value", answerValue),
                ("answer_text", answerText),
                ("block_type", blockType),
                ("block_id", blockId),
                ("answer_label", answerLabel),
                ("answer_options", answerOptions),
                ("scale_min", scaleMin),
                ("scale_max", scaleMax),
                ("time_to_answer_ms", timeToAnswerMs),
                ("answer", answer.isEmpty ? nil : answer),
            ])
        }
    }

    struct QuestionSkipped: EngageAnalyticsEvent {
        let questionId: String
        var questionTitle: String?
        var itemIndex: Int?
        var blockType: String?
        var blockId: String?

        var eventName: String { "Digia Question Skipped" }
        var properties: [String: Any] {
            nonNull([
                ("question_id", questionId),
                ("question_title", questionTitle),
                ("item_index", itemIndex),
                ("block_type", blockType),
                ("block_id", blockId),
            ])
        }
    }

    struct Dismissed: EngageAnalyticsEvent {
        var abandonedAtItem: Int?
        var itemTotal: Int?
        var answeredCount: Int?
        var dwellMs: Int64?

        var eventName: String { "Digia Experience Dismissed" }
        var properties: [String: Any] {
            nonNull([
                ("abandoned_at_item", abandonedAtItem),
                ("item_total", itemTotal),
                ("answered_count", answeredCount),
                ("dwell_ms", dwellMs),
            ])
        }
    }

    struct Completed: EngageAnalyticsEvent {
        var itemTotal: Int?
        var answeredCount: Int?
        var submissionId: String?
        var timeToCompleteMs: Int64?
        var response: [String: Any] = [:]

        var eventName: String { "Digia Experience Completed" }
        var properties: [String: Any] {
            nonNull([
                ("item_total", itemTotal),
                ("answered_count", answeredCount),
                ("submission_id", submissionId),
                ("time_to_complete_ms", timeToCompleteMs),
                ("response", response.isEmpty ? nil : response),
            ])
        }
    }
}

// ── Inline: carousel ────────────────────────────────────────────────────────

enum CarouselEvent {
    struct Viewed: EngageAnalyticsEvent {
        var itemTotal: Int?
        var slotKey: String?
        var screenName: String?

        var eventName: String { "Digia Experience Viewed" }
        var properties: [String: Any] {
            nonNull([
                ("display_style", "carousel"),
                ("item_total", itemTotal),
                ("slot_key", slotKey),
                ("screen_name", screenName),
            ])
        }
    }

    struct StepViewed: EngageAnalyticsEvent {
        let itemIndex: Int
        var itemTotal: Int?
        var itemId: String?
        /// True when the carousel auto-advanced to this item; false on a manual swipe.
        var auto: Bool?

        var eventName: String { "Digia Step Viewed" }
        var properties: [String: Any] {
            nonNull([
                ("item_index", itemIndex),
                ("item_total", itemTotal),
                ("item_id", itemId),
                ("auto", auto),
            ])
        }
    }

    struct StepClicked: EngageAnalyticsEvent {
        let itemIndex: Int
        var elementId: String?
        var ctaLabel: String?
        var actionType: String?
        var actionUrl: String?
        var itemId: String?

        var eventName: String { "Digia Step Clicked" }
        var properties: [String: Any] {
            nonNull([
                ("item_index", itemIndex),
                ("element_id", elementId),
                ("cta_label", ctaLabel),
                ("action_type", actionType),
                ("action_url", actionUrl),
                ("item_id", itemId),
            ])
        }
    }

    /// Carousel container tapped (non-item region).
    struct Clicked: EngageAnalyticsEvent {
        var elementId: String?
        var ctaLabel: String?
        var actionType: String?
        var actionUrl: String?

        var eventName: String { "Digia Experience Clicked" }
        var properties: [String: Any] {
            nonNull([
                ("element_id", elementId),
                ("cta_label", ctaLabel),
                ("action_type", actionType),
                ("action_url", actionUrl),
            ])
        }
    }
}

// ── Inline: stories ─────────────────────────────────────────────────────────

enum StoriesEvent {
    struct Viewed: EngageAnalyticsEvent {
        var itemTotal: Int?
        var slotKey: String?
        var screenName: String?

        var eventName: String { "Digia Experience Viewed" }
        var properties: [String: Any] {
            nonNull([
                ("display_style", "stories"),
                ("item_total", itemTotal),
                ("slot_key", slotKey),
                ("screen_name", screenName),
            ])
        }
    }

    /// A story is opened (ring/thumbnail tapped).
    struct Opened: EngageAnalyticsEvent {
        var storyId: String?

        var eventName: String { "Digia Experience Clicked" }
        var properties: [String: Any] {
            nonNull([
                ("element_id", "story_open"),
                ("story_id", storyId),
            ])
        }
    }

    struct StepViewed: EngageAnalyticsEvent {
        let itemIndex: Int
        var itemTotal: Int?
        var storyId: String?
        var frameId: String?

        var eventName: String { "Digia Step Viewed" }
        var properties: [String: Any] {
            nonNull([
                ("item_index", itemIndex),
                ("item_total", itemTotal),
                ("story_id", storyId),
                ("frame_id", frameId),
            ])
        }
    }

    struct StepClicked: EngageAnalyticsEvent {
        let itemIndex: Int
        var ctaLabel: String?
        var actionType: String?
        var actionUrl: String?
        var frameId: String?

        var eventName: String { "Digia Step Clicked" }
        var properties: [String: Any] {
            nonNull([
                ("item_index", itemIndex),
                ("cta_label", ctaLabel),
                ("action_type", actionType),
                ("action_url", actionUrl),
                ("frame_id", frameId),
            ])
        }
    }

    struct StepDismissed: EngageAnalyticsEvent {
        let itemIndex: Int

        var eventName: String { "Digia Step Dismissed" }
        var properties: [String: Any] { nonNull([("item_index", itemIndex)]) }
    }

    struct Completed: EngageAnalyticsEvent {
        var itemTotal: Int?
        var timeToCompleteMs: Int64?

        var eventName: String { "Digia Experience Completed" }
        var properties: [String: Any] {
            nonNull([
                ("item_total", itemTotal),
                ("time_to_complete_ms", timeToCompleteMs),
            ])
        }
    }
}

// MARK: - Helpers

/// Builds a wire map from named fields, dropping any whose value is nil.
///
/// Passing a typed optional (e.g. `Int?`) into an `Any?` slot yields a *nested*
/// optional (`.some(.none)`) that a plain `if let` would not treat as nil, so we
/// deep-unwrap each value first — the standard Swift workaround.
func nonNull(_ pairs: [(String, Any?)]) -> [String: Any] {
    var result: [String: Any] = [:]
    for (key, value) in pairs {
        if let unwrapped = deepUnwrap(value) { result[key] = unwrapped }
    }
    return result
}

/// Recursively unwraps nested optionals, returning nil for any `.none` at any
/// depth and the underlying value otherwise.
private func deepUnwrap(_ value: Any?) -> Any? {
    guard let value else { return nil }
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle == .optional else { return value }
    guard let child = mirror.children.first else { return nil }
    return deepUnwrap(child.value)
}

private extension Optional where Wrapped == TriggerContext {
    func orEmpty() -> [String: Any] { self?.asProperties() ?? [:] }
}
