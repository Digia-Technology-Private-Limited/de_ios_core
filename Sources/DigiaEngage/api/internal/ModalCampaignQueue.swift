import Foundation

// FIFO of organic modal campaigns routed while another modal was live (RN managed-mode
// sequential show). Dumb storage: all show/drop gating lives in `SDKInstance.route()`.
@MainActor
final class ModalCampaignQueue {
    private struct Entry {
        let campaignKey: String
        let payload: CEPTriggerPayload
    }

    private var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    // Appends unless the key is already queued (first trigger wins).
    // False when already queued; the caller drops the duplicate.
    @discardableResult
    func enqueue(campaignKey: String, payload: CEPTriggerPayload) -> Bool {
        guard !entries.contains(where: { $0.campaignKey == campaignKey }) else { return false }
        entries.append(Entry(campaignKey: campaignKey, payload: payload))
        return true
    }

    // Pops the head for `SDKInstance` to re-resolve and route.
    func pump() -> (campaignKey: String, payload: CEPTriggerPayload)? {
        guard !entries.isEmpty else { return nil }
        let head = entries.removeFirst()
        return (head.campaignKey, head.payload)
    }

    // Drops queued entries invalidated by `campaignId` (a payload identity,
    // not a key) — matches both, like Android.
    func remove(campaignId: String) {
        entries.removeAll { $0.campaignKey == campaignId || $0.payload.cepCampaignId == campaignId }
    }

    func clear() {
        entries.removeAll()
    }
}
