import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// The `events` the gamification server returns in an answer's `data.response`
/// (the `grantChance` answer, or the body of a proxied `http` `play` answer).
/// ADR 0002.
///
/// Never throws. A missing or non-array value is no events; an item without a
/// non-blank `name`, `eventId`, `occurredAt` and `campaignId` is skipped and
/// logged. Unknown fields are ignored, and a property keeps only a string,
/// number or boolean value; a null is dropped, as on Android.
func chanceEventsOf(_ raw: Any?, campaignKey: String? = nil) -> [ChanceAnalyticsEvent] {
    guard let items = raw as? [Any] else { return [] }
    var out: [ChanceAnalyticsEvent] = []
    for (index, item) in items.enumerated() {
        guard let event = (item as? [String: Any]).flatMap(chanceEventOrNil) else {
            log.w("Gamification chance event ignored — malformed (index=\(index))", campaign: campaignKey)
            continue
        }
        out.append(event)
    }
    return out
}

/// The events in a proxied `http` answer body (`{isSuccess, data: {response: {events}}}`).
func chanceEventsOfAnswer(_ body: Any?, campaignKey: String? = nil) -> [ChanceAnalyticsEvent] {
    let response = ((body as? [String: Any])?["data"] as? [String: Any])?["response"] as? [String: Any]
    return chanceEventsOf(response?["events"], campaignKey: campaignKey)
}

extension PlayDecision {
    /// The events a grant answer carried, whatever the decision it led to.
    var chanceEvents: [ChanceAnalyticsEvent] {
        switch self {
        case .open(let chance), .showEntry(let chance): return chance.events
        case .drop(_, _, let events): return events
        }
    }
}

extension EngageEventEmitter {
    /// Sends chance events to Digia analytics only — never the CEP (ADR 0002).
    func forwardChanceEvents(_ events: [ChanceAnalyticsEvent], payload: CEPTriggerPayload) {
        for event in events { toDigia(event, payload: payload) }
    }
}

private func chanceEventOrNil(_ item: [String: Any]) -> ChanceAnalyticsEvent? {
    func text(_ key: String) -> String? {
        guard let value = item[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }
    guard let name = text("name"), let eventId = text("eventId"),
          let occurredAt = text("occurredAt"), let campaignId = text("campaignId")
    else { return nil }
    return ChanceAnalyticsEvent(
        eventName: name, eventId: eventId, occurredAt: occurredAt,
        campaignId: campaignId, values: propertiesOf(item["properties"]))
}

private func propertiesOf(_ raw: Any?) -> [String: ChanceAnalyticsEvent.Value] {
    guard let json = raw as? [String: Any] else { return [:] }
    var out: [String: ChanceAnalyticsEvent.Value] = [:]
    for (key, value) in json {
        switch value {
        case let s as String:
            out[key] = .string(s)
        case let n as NSNumber:
            // JSONSerialization hands booleans and numbers both as NSNumber.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                out[key] = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                out[key] = .double(n.doubleValue)
            } else {
                out[key] = .int(n.int64Value)
            }
        default:
            continue
        }
    }
    return out
}
