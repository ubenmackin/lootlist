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
import UserNotifications

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
        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
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
        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
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
        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
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

    // MARK: - Concurrent-edit (serverRecordChanged) failure path re-fetches + re-upserts authoritative

    @Test
    func `updatePreference re-fetches and re-upserts authoritative on serverRecordChanged save failure`() async throws {
        resetUserDefaults()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
        // Inject the canonical optimistic-concurrency conflict: the production
        // `CloudKitService.save` wraps `CKError.serverRecordChanged` into
        // `CloudKitServiceError.serverRecordChanged`, which is exactly the
        // wrapped form `ConcurrentEditDetector` signal 1 matches on.
        ck.saveError = CloudKitServiceError.serverRecordChanged
        let cache = try CacheService(inMemory: true)
        let app = AppState()
        let profile = makeProfile(zoneID: zoneID)
        let family = makeFamily(zoneID: zoneID)
        app.currentProfile = profile
        app.family = family

        let service = NotificationService(cloudKit: ck, appState: app, cacheService: cache)

        // Pre-mutation cached preference — the snapshot the pre-fix failure
        // path would restore. Record name hits the existing-row branch in
        // `updatePreference` (snapshot.recordName), so the save targets THIS
        // record rather than minting a fresh UUID.
        let existingID = CKRecord.ID(recordName: "pref-hero1-questAssigned", zoneID: zoneID)
        let snapshotPref = NotificationPreference(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            eventType: .questAssigned,
            enabled: false,
            pushEnabled: false,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: existingID
        )
        cache.upsertNotificationPreference(snapshotPref)

        // Another device's authoritative version of the SAME record won the
        // race and shipped to the server before our save landed. The mock
        // store holds this record (the post-conflict server state a follow-up
        // `fetch` returns). It differs from BOTH the snapshot (enabled=false)
        // and the optimistic toggle we push (pushEnabled=true) so the cache
        // after-the-fact can prove WHICH value landed.
        let authoritative = NotificationPreference(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            eventType: .questAssigned,
            enabled: true,
            pushEnabled: false,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: existingID
        )
        ck.seedMockRecords([authoritative])

        // Sanity: cache reflects the snapshot (pre-mutation) before the save.
        let preRow = try #require(
            cache.fetchNotificationPreferences(profileRecordName: "hero1")
                .first(where: { $0.recordName == existingID.recordName })
        )
        #expect(preRow.enabled == false)
        #expect(preRow.pushEnabled == false)

        // The save fails with `serverRecordChanged`; signal 1 fires and the
        // failure path must re-fetch + re-upsert the authoritative server
        // record in place of either the snapshot OR the optimistic write.
        do {
            _ = try await service.updatePreference(event: .questAssigned, enabled: true)
            #expect(Bool(false), "Expected save to throw on serverRecordChanged")
        } catch {
            #expect((error as? NotificationServiceError) == .persistenceFailed)
        }

        let cachedRows = cache.fetchNotificationPreferences(profileRecordName: "hero1")
            .filter { $0.recordName == existingID.recordName }
        #expect(
            cachedRows.count == 1,
            "Cache must hold exactly one row for the preference after the conflict re-upsert"
        )
        let cached = try #require(cachedRows.first)
        #expect(
            cached.enabled == true,
            "Cache must hold the authoritative server value (enabled=true), not the stashed snapshot (enabled=false)"
        )
        #expect(
            cached.pushEnabled == false,
            "Cache must hold the authoritative server value (pushEnabled=false), not the optimistic write (pushEnabled=true)"
        )
    }

    // MARK: - Event Type Metadata & Role Relevance Tests

    @Test
    func `notification event types map correctly to categories and roles`() {
        #expect(NotificationEventType.questRejected.category == .quests)
        #expect(NotificationEventType.questRejected.displayName == "Quest Rejected")
        #expect(NotificationEventType.questRejected.iconSystemName == "xmark.seal.fill")

        #expect(NotificationEventType.questAssigned.isRelevantForHero == true)
        #expect(NotificationEventType.questAssigned.isRelevantForParent == false)

        #expect(NotificationEventType.questNeedsReview.isRelevantForHero == false)
        #expect(NotificationEventType.questNeedsReview.isRelevantForParent == true)

        #expect(NotificationEventType.questRejected.isRelevantForHero == true)
        #expect(NotificationEventType.questRejected.isRelevantForParent == false)

        #expect(NotificationEventType.spendingLogged.isRelevantForHero == false)
        #expect(NotificationEventType.spendingLogged.isRelevantForParent == true)

        #expect(NotificationEventType.levelUp.isRelevantForHero == true)
        #expect(NotificationEventType.levelUp.isRelevantForParent == true)
    }

    @Test
    func `deliverSyncNotification skips self notifications`() async throws {
        resetUserDefaults()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let app = AppState()
        let profile = makeProfile(zoneID: zoneID)
        app.currentProfile = profile

        let service = NotificationService(cloudKit: ck, appState: app, cacheService: cache)

        // deliverSyncNotification with matching profileID should return early without throwing
        try await service.deliverSyncNotification(
            eventType: .questCompleted,
            title: "Test",
            body: "Self notification",
            profileID: profile.id.recordName
        )
    }

    // MARK: - Deep-link payload carries the authoring peer (not the viewer)

    @Test
    func `deliverSyncNotification deep-link profileID carries the authoring peer, not the viewer`() async throws {
        resetUserDefaults()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let app = AppState()
        // The viewer is the receiver of the notification on this device.
        let viewer = makeProfile(zoneID: zoneID)
        app.currentProfile = viewer

        let service = NotificationService(cloudKit: ck, appState: app, cacheService: cache)

        // The authoring peer is the family member whose action triggered the
        // sync event (creator/completer/spender/verifier recordName).
        let authoringPeerID = "authorPeer"

        // Clean slate so the only pending request after delivery is ours.
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        defer { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }

        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])

        try await service.deliverSyncNotification(
            eventType: .questCompleted,
            title: "Quest Completed",
            body: "A hero completed a quest.",
            profileID: authoringPeerID
        )

        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let deliveredNotifications = await UNUserNotificationCenter.current().deliveredNotifications()

        let userInfo: [AnyHashable: Any] = try #require(
            pending.first(where: { $0.identifier.hasPrefix("\(NotificationEventType.questCompleted.rawValue):") })?.content.userInfo
                ?? deliveredNotifications.first(where: { $0.request.identifier.hasPrefix("\(NotificationEventType.questCompleted.rawValue):") })?.request.content.userInfo,
            "Expected a pending or delivered request with the questCompleted identifier prefix"
        )

        let payloadProfileID = try #require(
            userInfo["profileID"] as? String,
            "userInfo must carry a String profileID for deep-link routing"
        )
        #expect(
            payloadProfileID == authoringPeerID,
            "deep-link profileID must be the authoring peer (\"\(authoringPeerID)\"), not the viewer (\"\(viewer.id.recordName)\")"
        )
        #expect(payloadProfileID != viewer.id.recordName)
    }
}
