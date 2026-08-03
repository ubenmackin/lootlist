//
//  NotificationServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData
import Testing

@MainActor
struct NotificationServiceTests {
    // MARK: - Fixtures

    private static let userDefaultsKeysToReset = [
        "masterNotificationsEnabled",
        "questAssignedNotificationsEnabled",
        "questNeedsReviewNotificationsEnabled",
        "questVerifiedNotificationsEnabled",
        "levelUpNotificationsEnabled",
        "weeklySummaryNotificationsEnabled"
    ]

    private func resetUserDefaults() {
        for key in Self.userDefaultsKeysToReset {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makeProfile(zoneID: CKRecordZone.ID) -> Profile {
        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID),
            action: .none
        )
        let userID = CKRecord.ID(recordName: "u1", zoneID: zoneID)
        return Profile(
            displayName: "Test Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: userID,
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
    }

    private func makeFamily(zoneID: CKRecordZone.ID) -> Family {
        Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            payoutPolicy: .perQuest,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
    }

    @Test
    func `updatePreference writes through to cache and cloudkit`() async throws {
        resetUserDefaults()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let ck = CloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let app = AppState()
        app.currentProfile = makeProfile(zoneID: zoneID)
        app.family = makeFamily(zoneID: zoneID)

        let service = NotificationService(cloudKit: ck, appState: app, cacheService: cache)

        // Cache is empty pre-toggle → default-true fallback.
        #expect(service.isNotificationEnabled(for: .questAssigned) == true)

        let saved = try await service.updatePreference(event: .questAssigned, enabled: false)

        // CK round-trip: the saved record carries the new value + a stable record name.
        #expect(saved.enabled == false)
        #expect(saved.pushEnabled == false)
        #expect(saved.eventType == .questAssigned)
        #expect(!saved.id.recordName.isEmpty)

        // Cache holds the post-save row (re-upserted after the CK save).
        let cachedRows = cache.fetchNotificationPreferences(profileRecordName: "hero1")
        #expect(cachedRows.count == 1)
        #expect(cachedRows.first?.enabled == false)
        #expect(cachedRows.first?.eventType == NotificationEventType.questAssigned.rawValue)

        // A completed sync pass stamped this family's preference cache fresh,
        // so the canonical read trusts the cached row (not just the mirror).
        cache.markCacheFresh(familyRecordName: "fam1", type: .notificationPreference)

        // The canonical read path now reflects the cached value.
        #expect(service.isNotificationEnabled(for: .questAssigned) == false)

        // The UserDefaults mirror was also written for fallback continuity.
        #expect(UserDefaults.standard.object(forKey: "questAssignedNotificationsEnabled") as? Bool == false)
    }

    @Test
    func `isNotificationEnabled reflects remote preference change via backgroundCache upsert`() async throws {
        resetUserDefaults()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let ck = CloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let app = AppState()
        app.currentProfile = makeProfile(zoneID: zoneID)
        app.family = makeFamily(zoneID: zoneID)

        let service = NotificationService(cloudKit: ck, appState: app, cacheService: cache)

        // Empty cache → default-true fallback for level-up.
        #expect(service.isNotificationEnabled(for: .levelUp) == true)

        // Another device writes a `NotificationPreference` (enabled=false) and
        let backgroundCache = try BackgroundCacheActor(container: #require(cache.container))
        let remote = NotificationPreference(
            profile: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID),
                action: .none
            ),
            eventType: .levelUp,
            enabled: false,
            pushEnabled: false,
            family: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID),
                action: .none
            ),
            id: CKRecord.ID(recordName: "remote-pref-1", zoneID: zoneID)
        )
        await backgroundCache.batchUpsertNotificationPreferences([remote])
        // SyncEngine stamps freshness after a successful sync pass — model that
        // here so the read-first gate trusts the remotely-written row.
        cache.markCacheFresh(familyRecordName: "fam1", type: .notificationPreference)

        // Next read picks up the remotely-written value — proving the cache
        // (not UserDefaults) is the read source for a populated, fresh row.
        #expect(service.isNotificationEnabled(for: .levelUp) == false,
                "isNotificationEnabled must reflect the cached remote mutation, not the stale default")
    }

    @Test
    func `isNotificationEnabled falls back to userDefaults when cache is empty`() throws {
        resetUserDefaults()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let ck = CloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let app = AppState()
        app.currentProfile = makeProfile(zoneID: zoneID)
        app.family = makeFamily(zoneID: zoneID)

        let service = NotificationService(cloudKit: ck, appState: app, cacheService: cache)

        // No cache rows, no UserDefaults entry → default-true fallback.
        #expect(service.isNotificationEnabled(for: .questAssigned) == true)

        // Mirror a "user disabled this" state into UserDefaults (as the
        // write-through setter does) without touching the cache.
        UserDefaults.standard.set(false, forKey: "questAssignedNotificationsEnabled")
        #expect(service.isNotificationEnabled(for: .questAssigned) == false,
                "first-launch fallback must honor the UserDefaults mirror write")

        // Master toggle gates the fallback.
        UserDefaults.standard.set(false, forKey: "masterNotificationsEnabled")
        #expect(service.isNotificationEnabled(for: .questAssigned) == false,
                "master toggle off must disable all events via the fallback path")
        UserDefaults.standard.set(true, forKey: "masterNotificationsEnabled")
        #expect(service.isNotificationEnabled(for: .questAssigned) == false,
                "master back on restores the per-event fallback value")
    }
}
