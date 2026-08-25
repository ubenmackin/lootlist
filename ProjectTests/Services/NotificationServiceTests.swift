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
    // MARK: - iCloud Guard

    /// The simulator periodically loses its iCloud login. Tests that spin up
    /// the real sync engine hang forever without an authenticated account,
    /// so callers skip instead.
    /// Returns `false` (skip) when no iCloud account is available.
    private static func iCloudAccountAvailable() async -> Bool {
        // Race accountStatus against a timeout so even this call can't hang.
        let status: CKAccountStatus? = await withTaskGroup(of: CKAccountStatus?.self) { group in
            group.addTask { await (try? CKContainer.default().accountStatus()) ?? .couldNotDetermine }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return status == .available
    }

    // MARK: - Fixtures

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
        guard await Self.iCloudAccountAvailable() else {
            print("SKIPPED: no iCloud account on simulator (sync engine would hang)")
            return
        }

        let defaults = UserDefaults.ephemeral()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let app = AppState(defaults: defaults)
        app.currentProfile = makeProfile(zoneID: zoneID)
        app.family = makeFamily(zoneID: zoneID)

        let service = NotificationService(cloudKit: ck, appState: app, cacheService: cache, defaults: defaults)

        // Cache is empty pre-toggle and defaults unset → default-false fallback.
        #expect(service.isNotificationEnabled(for: .questAssigned) == false)

        let saved = try await service.updatePreference(event: .questAssigned, enabled: true)

        // CK round-trip: the saved record carries the new value + a stable record name.
        #expect(saved.enabled == true)
        #expect(saved.eventType == .questAssigned)
        #expect(!saved.id.recordName.isEmpty)

        // Cache holds the post-save row (re-upserted after the CK save).
        let cachedRows = cache.fetchNotificationPreferences(profileRecordName: "hero1")
        #expect(cachedRows.count == 1)
        #expect(cachedRows.first?.enabled == true)
        #expect(cachedRows.first?.eventType == NotificationEventType.questAssigned.rawValue)

        // A completed sync pass stamped this family's preference cache fresh,
        // so the canonical read trusts the cached row (not just the mirror).
        cache.markCacheFresh(familyRecordName: "fam1", type: .notificationPreference)

        // The canonical read path now reflects the cached value.
        #expect(service.isNotificationEnabled(for: .questAssigned) == true)

        // The UserDefaults mirror was also written for fallback continuity.
        #expect(defaults.object(forKey: "questAssignedNotificationsEnabled") as? Bool == true)
    }

    @Test
    func `isNotificationEnabled reflects remote preference change via backgroundCache upsert`() async throws {
        guard await Self.iCloudAccountAvailable() else {
            print("SKIPPED: no iCloud account on simulator (sync engine would hang)")
            return
        }

        let defaults = UserDefaults.ephemeral()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let app = AppState(defaults: defaults)
        app.currentProfile = makeProfile(zoneID: zoneID)
        app.family = makeFamily(zoneID: zoneID)

        let service = NotificationService(cloudKit: ck, appState: app, cacheService: cache, defaults: defaults)

        // Empty cache and defaults unset → default-false fallback for level-up.
        #expect(service.isNotificationEnabled(for: .levelUp) == false)

        // Another device writes a `NotificationPreference` (enabled=true) and
        let backgroundCache = try BackgroundCacheActor(container: #require(cache.container))
        let remote = NotificationPreference(
            profile: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID),
                action: .none
            ),
            eventType: .levelUp,
            enabled: true,
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
        #expect(service.isNotificationEnabled(for: .levelUp) == true,
                "isNotificationEnabled must reflect the cached remote mutation, not the stale default")
    }

    @Test
    func `isNotificationEnabled falls back to userDefaults when cache is empty`() throws {
        let defaults = UserDefaults.ephemeral()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let app = AppState(defaults: defaults)
        app.currentProfile = makeProfile(zoneID: zoneID)
        app.family = makeFamily(zoneID: zoneID)

        let service = NotificationService(cloudKit: ck, appState: app, cacheService: cache, defaults: defaults)

        // No cache rows, no UserDefaults entry → default-false fallback.
        #expect(service.isNotificationEnabled(for: .questAssigned) == false)

        // Set UserDefaults master + event enabled
        defaults.set(true, forKey: "masterNotificationsEnabled")
        defaults.set(true, forKey: "questAssignedNotificationsEnabled")
        #expect(service.isNotificationEnabled(for: .questAssigned) == true,
                "first-launch fallback must honor the UserDefaults mirror write")

        // Master toggle gates the fallback.
        defaults.set(false, forKey: "masterNotificationsEnabled")
        #expect(service.isNotificationEnabled(for: .questAssigned) == false,
                "master toggle off must disable all events via the fallback path")
        defaults.set(true, forKey: "masterNotificationsEnabled")
        #expect(service.isNotificationEnabled(for: .questAssigned) == true,
                "master back on restores the per-event fallback value")
    }

    // MARK: - Concurrent-edit (serverRecordChanged) failure path re-fetches + re-upserts authoritative

    @Test
    func `updatePreference re-fetches and re-upserts authoritative on serverRecordChanged save failure`() async throws {
        guard await Self.iCloudAccountAvailable() else {
            print("SKIPPED: no iCloud account on simulator (sync engine would hang)")
            return
        }

        let defaults = UserDefaults.ephemeral()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
        // Inject save conflict error for verification.
        ck.saveError = CloudKitServiceError.serverRecordChanged
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let app = AppState(defaults: defaults)
        let profile = makeProfile(zoneID: zoneID)
        let family = makeFamily(zoneID: zoneID)
        app.currentProfile = profile
        app.family = family

        let service = NotificationService(cloudKit: ck, appState: app, cacheService: cache, defaults: defaults)

        // Seed existing cached preference record name for in-place update.
        let existingID = CKRecord.ID(recordName: "pref-hero1-fam1-questAssigned", zoneID: zoneID)
        let snapshotPref = NotificationPreference(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            eventType: .questAssigned,
            enabled: false,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: existingID
        )
        cache.upsertNotificationPreference(snapshotPref)

        // Another device's authoritative version of the SAME record won the
        // race and shipped to the server before our save landed. The mock
        // store holds this record (the post-conflict server state a follow-up
        // `fetch` returns).
        let authoritative = NotificationPreference(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            eventType: .questAssigned,
            enabled: true,
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

        _ = try await service.updatePreference(event: .questAssigned, enabled: true)

        let cachedRows = cache.fetchNotificationPreferences(profileRecordName: "hero1")
            .filter { $0.recordName == existingID.recordName }
        #expect(
            cachedRows.count == 1,
            "Cache must hold exactly one row for the preference after the update"
        )
        let cached = try #require(cachedRows.first)
        #expect(
            cached.enabled == true,
            "Cache must hold the updated value (enabled=true)"
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
        guard await Self.iCloudAccountAvailable() else {
            print("SKIPPED: no iCloud account on simulator (sync engine would hang)")
            return
        }

        let defaults = UserDefaults.ephemeral()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let app = AppState(defaults: defaults)
        let profile = makeProfile(zoneID: zoneID)
        app.currentProfile = profile

        let service = NotificationService(cloudKit: ck, appState: app, cacheService: cache, defaults: defaults)

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
        guard await Self.iCloudAccountAvailable() else {
            print("⏭️ Skipped: no iCloud account on simulator (sync engine would hang)")
            return
        }
        let defaults = UserDefaults.ephemeral()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let app = AppState(defaults: defaults)
        // The viewer is the receiver of the notification on this device.
        let viewer = makeProfile(zoneID: zoneID)
        app.currentProfile = viewer

        defaults.set(true, forKey: "masterNotificationsEnabled")
        defaults.set(true, forKey: "questVerifiedNotificationsEnabled")

        let service = NotificationService(cloudKit: ck, appState: app, cacheService: cache, defaults: defaults)

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

    @Test
    func `sendQuestRejected delivers notification to recipient hero`() async throws {
        guard await Self.iCloudAccountAvailable() else {
            print("SKIPPED: no iCloud account on simulator (sync engine would hang)")
            return
        }

        let defaults = UserDefaults.ephemeral()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let ck = MockCloudKitService()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let app = AppState(defaults: defaults)
        let hero = makeProfile(zoneID: zoneID)
        let family = makeFamily(zoneID: zoneID)
        app.currentProfile = hero
        app.family = family

        defaults.set(true, forKey: "masterNotificationsEnabled")
        defaults.set(true, forKey: "questRejectedNotificationsEnabled")

        let service = NotificationService(cloudKit: ck, appState: app, cacheService: cache, defaults: defaults)

        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        defer { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }

        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])

        let questRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "quest1", zoneID: zoneID), action: .none)
        let heroRef = CKRecord.Reference(recordID: hero.id, action: .none)
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let log = QuestCompletion(
            quest: questRef,
            completedBy: heroRef,
            approvalMode: .parentVerify,
            weekOf: Date(),
            family: familyRef,
            id: CKRecord.ID(recordName: "log1", zoneID: zoneID)
        )

        try await service.sendQuestRejected(questLog: log, to: hero)

        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let deliveredNotifications = await UNUserNotificationCenter.current().deliveredNotifications()

        let matching = pending.first(where: { $0.identifier.hasPrefix("\(NotificationEventType.questRejected.rawValue):") })
            ?? deliveredNotifications.first(where: { $0.request.identifier.hasPrefix("\(NotificationEventType.questRejected.rawValue):") })?.request

        #expect(matching != nil, "Expected a notification request for questRejected")
    }

    @Test
    func `sendQuestNeedsReview honors recipient parent preference`() async throws {
        guard await Self.iCloudAccountAvailable() else {
            print("SKIPPED: no iCloud account on simulator (sync engine would hang)")
            return
        }

        let defaults = UserDefaults.ephemeral()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let ck = MockCloudKitService()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let app = AppState(defaults: defaults)
        let hero = makeProfile(zoneID: zoneID)
        let family = makeFamily(zoneID: zoneID)
        app.currentProfile = hero
        app.family = family

        let parent = Profile(
            displayName: "Parent User",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .ranger,
            iCloudUserID: CKRecord.ID(recordName: "u2", zoneID: zoneID),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "parent1", zoneID: zoneID)
        )

        // Store disabled preference for parent
        let pref = NotificationPreference(
            profile: CKRecord.Reference(recordID: parent.id, action: .none),
            eventType: .questNeedsReview,
            enabled: false,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "pref-parent1-fam1-questNeedsReview", zoneID: zoneID)
        )
        cache.upsertNotificationPreference(pref)
        cache.markCacheFresh(familyRecordName: "fam1", type: .notificationPreference)

        let service = NotificationService(cloudKit: ck, appState: app, cacheService: cache, defaults: defaults)

        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        defer { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }

        let questRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "quest1", zoneID: zoneID), action: .none)
        let heroRef = CKRecord.Reference(recordID: hero.id, action: .none)
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let log = QuestCompletion(
            quest: questRef,
            completedBy: heroRef,
            approvalMode: .parentVerify,
            weekOf: Date(),
            family: familyRef,
            id: CKRecord.ID(recordName: "log1", zoneID: zoneID)
        )

        try await service.sendQuestNeedsReview(questLog: log, to: parent)

        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let matching = pending.filter { $0.identifier.hasPrefix("questNeedsReview:") }
        #expect(matching.isEmpty, "Notification should be suppressed based on recipient parent's disabled preference")
    }

    @Test
    func `deliverSyncNotification delivers for peer events and skips self-notifications`() async throws {
        guard await Self.iCloudAccountAvailable() else {
            print("SKIPPED: no iCloud account on simulator (sync engine would hang)")
            return
        }

        let defaults = UserDefaults.ephemeral()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let ck = MockCloudKitService()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let app = AppState(defaults: defaults)
        let hero = makeProfile(zoneID: zoneID)
        let family = makeFamily(zoneID: zoneID)
        app.currentProfile = hero
        app.family = family

        defaults.set(true, forKey: "masterNotificationsEnabled")
        defaults.set(true, forKey: "questAssignedNotificationsEnabled")

        let service = NotificationService(cloudKit: ck, appState: app, cacheService: cache, defaults: defaults)

        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        defer { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }

        // 1. Self notification should be skipped
        try await service.deliverSyncNotification(
            eventType: .questAssigned,
            title: "Self Quest",
            body: "Self body",
            profileID: hero.id.recordName
        )
        var pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        #expect(pending.isEmpty, "Self notifications should be skipped")

        // 2. Peer event notification should be scheduled
        try await service.deliverSyncNotification(
            eventType: .questAssigned,
            title: "Peer Quest",
            body: "Peer assigned quest",
            profileID: "parent1"
        )
        pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        #expect(!pending.isEmpty, "Peer notification should be delivered")
    }
}
