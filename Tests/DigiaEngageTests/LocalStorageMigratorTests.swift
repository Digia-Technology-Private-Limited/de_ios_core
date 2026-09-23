import Foundation
import Testing
@testable import DigiaEngage

@Suite("LocalStorageMigrator Tests")
struct LocalStorageMigratorTests {
    private func makeIsolatedDefaults() -> (UserDefaults, UserDefaults) {
        let targetName = "test.target.\(UUID().uuidString)"
        let standardName = "test.standard.\(UUID().uuidString)"
        let targetDefaults = UserDefaults(suiteName: targetName)!
        let standardDefaults = UserDefaults(suiteName: standardName)!
        targetDefaults.removePersistentDomain(forName: targetName)
        standardDefaults.removePersistentDomain(forName: standardName)
        return (targetDefaults, standardDefaults)
    }

    @Test("Migrates all legacy keys to unified format and deletes legacy keys")
    func testFullMigration() {
        let (targetDefaults, standardDefaults) = makeIsolatedDefaults()

        // Populate standard defaults with legacy keys
        standardDefaults.set("anon-1234", forKey: "digia_anonymous_id")
        standardDefaults.set("user-5678", forKey: "digia_user_id")
        let queueJson = "[{\"event_id\":\"evt_1\",\"payload\":{},\"created_at\":1000,\"attempts\":0}]"
        standardDefaults.set(queueJson.data(using: .utf8), forKey: "digia_analytics_queue")
        standardDefaults.set("{\"total\":3}", forKey: "freq:camp_promo")
        standardDefaults.set("{\"total\":1}", forKey: "freq:camp_banner")
        standardDefaults.set(true, forKey: "digia_debug_overlay_bubble_visible")
        standardDefaults.set(true, forKey: "digia_anchorless_capture_enabled")
        standardDefaults.set(true, forKey: "digia_anchorless_capture_include_text")
        standardDefaults.set(false, forKey: "digia_anchorless_capture_include_media")
        standardDefaults.set(true, forKey: "digia_anchorless_capture_include_structure")
        standardDefaults.set(true, forKey: "digia_component_registry_recording_enabled")
        standardDefaults.set(true, forKey: "digia_live_testing_enabled")
        standardDefaults.set("Tester iPhone", forKey: "digia_live_testing_device_name")

        // Perform migration
        LocalStorageMigrator.migrateIfNeeded(targetDefaults: targetDefaults, standardDefaults: standardDefaults)

        // Verify target defaults have migrated values
        #expect(targetDefaults.integer(forKey: "storage.version") == 1)
        #expect(targetDefaults.string(forKey: "identity.device_id") == "anon-1234")
        #expect(targetDefaults.string(forKey: "identity.anonymous_id") == nil)
        #expect(targetDefaults.string(forKey: "identity.user_id") == "user-5678")
        #expect(targetDefaults.string(forKey: "analytics.queue") == queueJson)
        #expect(targetDefaults.string(forKey: "frequency.camp_promo") == "{\"total\":3}")
        #expect(targetDefaults.string(forKey: "frequency.camp_banner") == "{\"total\":1}")
        #expect(targetDefaults.bool(forKey: "debug.overlay_visible") == true)
        #expect(targetDefaults.bool(forKey: "capture.enabled") == true)
        #expect(targetDefaults.bool(forKey: "capture.include_text") == true)
        #expect(targetDefaults.bool(forKey: "capture.include_media") == false)
        #expect(targetDefaults.bool(forKey: "capture.include_structure") == true)
        #expect(targetDefaults.bool(forKey: "registry.recording_enabled") == true)
        #expect(targetDefaults.bool(forKey: "live_test.enabled") == true)
        #expect(targetDefaults.string(forKey: "live_test.device_name") == "Tester iPhone")

        // Verify legacy keys removed from standard defaults
        #expect(standardDefaults.string(forKey: "digia_anonymous_id") == nil)
        #expect(standardDefaults.string(forKey: "digia_user_id") == nil)
        #expect(standardDefaults.data(forKey: "digia_analytics_queue") == nil)
        #expect(standardDefaults.string(forKey: "freq:camp_promo") == nil)
        #expect(standardDefaults.string(forKey: "freq:camp_banner") == nil)
        #expect(standardDefaults.object(forKey: "digia_debug_overlay_bubble_visible") == nil)
        #expect(standardDefaults.object(forKey: "digia_anchorless_capture_enabled") == nil)
        #expect(standardDefaults.object(forKey: "digia_anchorless_capture_include_text") == nil)
        #expect(standardDefaults.object(forKey: "digia_anchorless_capture_include_media") == nil)
        #expect(standardDefaults.object(forKey: "digia_anchorless_capture_include_structure") == nil)
        #expect(standardDefaults.object(forKey: "digia_component_registry_recording_enabled") == nil)
        #expect(standardDefaults.object(forKey: "digia_live_testing_enabled") == nil)
        #expect(standardDefaults.string(forKey: "digia_live_testing_device_name") == nil)
    }

    @Test("Migrates legacy engage device id when anonymous id is absent")
    func testFallbackToEngageDeviceId() {
        let (targetDefaults, standardDefaults) = makeIsolatedDefaults()
        standardDefaults.set("dev-id-789", forKey: "digia_engage_device_id")

        LocalStorageMigrator.migrateIfNeeded(targetDefaults: targetDefaults, standardDefaults: standardDefaults)

        #expect(targetDefaults.string(forKey: "identity.device_id") == "dev-id-789")
        #expect(targetDefaults.string(forKey: "identity.anonymous_id") == nil)
        #expect(standardDefaults.string(forKey: "digia_engage_device_id") == nil)
    }

    @Test("Migrates string formatted queue")
    func testQueueStringMigration() {
        let (targetDefaults, standardDefaults) = makeIsolatedDefaults()
        let queueJson = "[{\"event_id\":\"str_1\"}]"
        standardDefaults.set(queueJson, forKey: "digia_analytics_queue")

        LocalStorageMigrator.migrateIfNeeded(targetDefaults: targetDefaults, standardDefaults: standardDefaults)

        #expect(targetDefaults.string(forKey: "analytics.queue") == queueJson)
        #expect(standardDefaults.string(forKey: "digia_analytics_queue") == nil)
    }

    @Test("Skips migration if storage version is already at current version")
    func testIdempotency() {
        let (targetDefaults, standardDefaults) = makeIsolatedDefaults()
        targetDefaults.set(1, forKey: "storage.version")
        targetDefaults.set("already-migrated", forKey: "identity.device_id")
        standardDefaults.set("old-id", forKey: "digia_anonymous_id")

        LocalStorageMigrator.migrateIfNeeded(targetDefaults: targetDefaults, standardDefaults: standardDefaults)

        // Target should be untouched
        #expect(targetDefaults.string(forKey: "identity.device_id") == "already-migrated")
        // Standard should still retain old-id because migration skipped
        #expect(standardDefaults.string(forKey: "digia_anonymous_id") == "old-id")
    }

    @Test("Deletes orphaned video cache directory during migration")
    func testVideoCacheDirectoryCleanup() {
        let (targetDefaults, standardDefaults) = makeIsolatedDefaults()
        if let cachesUrl = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let legacyDir = cachesUrl.appendingPathComponent("digia-engage-story-video-files")
            try? FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
            #expect(FileManager.default.fileExists(atPath: legacyDir.path))

            LocalStorageMigrator.migrateIfNeeded(targetDefaults: targetDefaults, standardDefaults: standardDefaults)

            #expect(!FileManager.default.fileExists(atPath: legacyDir.path))
        }
    }
}
