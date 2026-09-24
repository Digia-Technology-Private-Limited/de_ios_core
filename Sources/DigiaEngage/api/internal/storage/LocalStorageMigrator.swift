import Foundation

enum LocalStorageMigrator {
    private static let suiteName = "tech.digia.engage"
    private static let keyStorageVersion = "storage.version"
    private static let currentStorageVersion = 1

    static func migrateIfNeeded(
        targetDefaults: UserDefaults? = UserDefaults(suiteName: suiteName) ?? .standard,
        standardDefaults: UserDefaults = .standard
    ) {
        guard let targetDefaults else { return }
        let currentVersion = targetDefaults.integer(forKey: keyStorageVersion)
        guard currentVersion < currentStorageVersion else { return }

        // 1. Identity Migration. Each legacy source is tried on its own, and
        // a copy counts only once it reads back from the target: a legacy
        // identity key is deleted, and the migration marked done, only then.
        var identityCopied = true
        let legacyId = ["digia_anonymous_id", "digia_engage_device_id"].lazy
            .compactMap { standardDefaults.string(forKey: $0) }
            .first { !$0.isEmpty }
        if let legacyId {
            targetDefaults.set(legacyId, forKey: "identity.device_id")
            identityCopied = targetDefaults.string(forKey: "identity.device_id") == legacyId
        }

        if let userId = standardDefaults.string(forKey: "digia_user_id"), !userId.isEmpty {
            targetDefaults.set(userId, forKey: "identity.user_id")
            identityCopied = identityCopied && targetDefaults.string(forKey: "identity.user_id") == userId
        }

        // 2. Analytics Queue Migration (standardized to String JSON across all stacks).
        // Merged into any unified queue already there (an interrupted earlier
        // run), never overwriting it.
        let legacyQueue = standardDefaults.data(forKey: "digia_analytics_queue")
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? standardDefaults.string(forKey: "digia_analytics_queue")
        if let merged = mergeQueues(
            legacy: legacyQueue,
            target: targetDefaults.string(forKey: "analytics.queue"),
            maxEvents: AnalyticsConfig().queueMaxEvents
        ) {
            targetDefaults.set(merged, forKey: "analytics.queue")
        }

        // 3. Frequency Capping Migration (freq:<campaignKey>)
        let allKeys = standardDefaults.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix("freq:") {
            let campaignKey = String(key.dropFirst("freq:".count))
            if let value = standardDefaults.string(forKey: key) {
                targetDefaults.set(value, forKey: "frequency.\(campaignKey)")
            }
        }

        // 4. Debug Overlay
        if standardDefaults.object(forKey: "digia_debug_overlay_bubble_visible") != nil {
            targetDefaults.set(
                standardDefaults.bool(forKey: "digia_debug_overlay_bubble_visible"),
                forKey: "debug.overlay_visible"
            )
        }

        // 5. Capture Profile
        if standardDefaults.object(forKey: "digia_anchorless_capture_enabled") != nil {
            targetDefaults.set(
                standardDefaults.bool(forKey: "digia_anchorless_capture_enabled"),
                forKey: "capture.enabled"
            )
        }
        if standardDefaults.object(forKey: "digia_anchorless_capture_include_text") != nil {
            targetDefaults.set(
                standardDefaults.bool(forKey: "digia_anchorless_capture_include_text"),
                forKey: "capture.include_text"
            )
        }
        if standardDefaults.object(forKey: "digia_anchorless_capture_include_media") != nil {
            targetDefaults.set(
                standardDefaults.bool(forKey: "digia_anchorless_capture_include_media"),
                forKey: "capture.include_media"
            )
        }
        if standardDefaults.object(forKey: "digia_anchorless_capture_include_structure") != nil {
            targetDefaults.set(
                standardDefaults.bool(forKey: "digia_anchorless_capture_include_structure"),
                forKey: "capture.include_structure"
            )
        }

        // 6. Component Registry
        if standardDefaults.object(forKey: "digia_component_registry_recording_enabled") != nil {
            targetDefaults.set(
                standardDefaults.bool(forKey: "digia_component_registry_recording_enabled"),
                forKey: "registry.recording_enabled"
            )
        }

        // 7. Live Testing
        if standardDefaults.object(forKey: "digia_live_testing_enabled") != nil {
            targetDefaults.set(
                standardDefaults.bool(forKey: "digia_live_testing_enabled"),
                forKey: "live_test.enabled"
            )
        }
        if let deviceName = standardDefaults.string(forKey: "digia_live_testing_device_name") {
            targetDefaults.set(deviceName, forKey: "live_test.device_name")
        }

        // 8. Delete Legacy Keys from standard defaults
        let identityKeys = identityCopied
            ? ["digia_anonymous_id", "digia_engage_device_id", "digia_user_id"]
            : []
        let legacyKeys = identityKeys + [
            "digia_analytics_queue",
            "digia_debug_overlay_bubble_visible",
            "digia_anchorless_capture_enabled",
            "digia_anchorless_capture_include_text",
            "digia_anchorless_capture_include_media",
            "digia_anchorless_capture_include_structure",
            "digia_component_registry_recording_enabled",
            "digia_live_testing_enabled",
            "digia_live_testing_device_name",
        ] + allKeys.filter { $0.hasPrefix("freq:") }

        for key in legacyKeys {
            standardDefaults.removeObject(forKey: key)
        }

        // A failed identity copy leaves the marker unset, so the next launch
        // retries it. Initialization proceeds either way.
        if identityCopied {
            targetDefaults.set(currentStorageVersion, forKey: keyStorageVersion)
        }

        // ─────────────────────────────────────────────────────────────────────────────
        // TEMPORARY MIGRATION CLEANUP: Delete orphaned legacy video cache directory.
        // Can be safely removed in a future release once older app versions cycle out.
        // ─────────────────────────────────────────────────────────────────────────────
        if let cachesUrl = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let legacyDir = cachesUrl.appendingPathComponent("digia-engage-story-video-files")
            try? FileManager.default.removeItem(at: legacyDir)
        }
    }

    /// Legacy entries first (they predate the unified queue), then the unified
    /// ones; an `event_id` present in both keeps its unified copy. Past
    /// `maxEvents` the oldest are dropped. Nil when there is nothing to write.
    static func mergeQueues(legacy: String?, target: String?, maxEvents: Int) -> String? {
        func entries(_ raw: String?) -> [[String: Any]] {
            guard let raw,
                  let list = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Any]
            else { return [] }
            return list.compactMap { entry in
                guard let entry = entry as? [String: Any],
                      let eventId = entry["event_id"] as? String, !eventId.isEmpty
                else { return nil }
                return entry
            }
        }
        let targetEntries = entries(target)
        let targetIds = Set(targetEntries.compactMap { $0["event_id"] as? String })
        var seen = Set<String>()
        let legacyOnly = entries(legacy).filter { entry in
            let eventId = entry["event_id"] as? String ?? ""
            return !targetIds.contains(eventId) && seen.insert(eventId).inserted
        }
        let merged = Array((legacyOnly + targetEntries).suffix(maxEvents))
        guard !merged.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: merged)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
