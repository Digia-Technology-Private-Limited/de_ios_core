import Foundation

enum CampaignTrigger: Equatable {
    case appStart
    case screen([String])
    case appEvent(String)

    static func fromJson(_ json: [String: Any]?) -> CampaignTrigger? {
        guard let json else { return nil }
        switch (json["type"] as? String) ?? "" {
        case "app_start": return .appStart
        case "screen":
            let names = parseScreenNames(json)
            return names.isEmpty ? nil : .screen(names)
        case "app_event":
            let name = ((json["eventName"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : .appEvent(name)
        default: return nil
        }
    }

    private static func parseScreenNames(_ json: [String: Any]) -> [String] {
        guard let arr = json["screenNames"] as? [Any] else { return [] }
        var names: [String] = []
        for entry in arr {
            guard let name = (entry as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }
}

let selfTriggeredCepPrefix = "digia_trigger:"

func selfTriggeredCepId(campaignId: String, firing: Int64) -> String {
    "\(selfTriggeredCepPrefix)\(campaignId)#\(firing)"
}

func isSelfTriggeredCepId(_ cepCampaignId: String) -> Bool {
    cepCampaignId.hasPrefix(selfTriggeredCepPrefix)
}
