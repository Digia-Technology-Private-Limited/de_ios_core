import Foundation

/// Maps each signal to the Digia-owned campaigns whose rule listens for it, so
/// a signal evaluates only those. Built again when the catalog changes.
struct TriggerIndex {
    private var listeners: [String: [(Int, CampaignModel)]] = [:]
    /// A rule this SDK cannot read has no triggers, so every signal reports it.
    private var unusable: [(Int, CampaignModel)] = []

    init(_ campaigns: [CampaignModel]) {
        var position = 0
        for campaign in campaigns {
            add(position, campaign)
            position += 1
        }
    }

    private mutating func add(_ position: Int, _ campaign: CampaignModel) {
        guard let rule = campaign.rule else { return }
        switch rule {
        case .invalid:
            unusable.append((position, campaign))
        case .valid(let valid):
            var seen: Set<String> = []
            for trigger in valid.triggers {
                for key in trigger.listeningKeys where seen.insert(key).inserted {
                    listeners[key, default: []].append((position, campaign))
                }
            }
        }
    }

    /// In catalog order.
    func listeningTo(_ signal: RuleSignal) -> [CampaignModel] {
        let listening = listeners[signal.indexKey] ?? []
        guard !unusable.isEmpty else { return listening.map { $0.1 } }
        return Self.byPosition(listening, unusable).map { $0.1 }
    }

    /// Merges two position-ordered lists, keeping catalog order.
    private static func byPosition(
        _ listening: [(Int, CampaignModel)],
        _ unusable: [(Int, CampaignModel)]
    ) -> [(Int, CampaignModel)] {
        var merged: [(Int, CampaignModel)] = []
        var i = 0
        var j = 0
        while i < listening.count && j < unusable.count {
            if listening[i].0 < unusable[j].0 {
                merged.append(listening[i])
                i += 1
            } else {
                merged.append(unusable[j])
                j += 1
            }
        }
        merged.append(contentsOf: listening[i...])
        merged.append(contentsOf: unusable[j...])
        return merged
    }
}
