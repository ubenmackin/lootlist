//
//  SyncEngineTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData
import Testing

// MARK: - Core Sync Engine Tests

@MainActor
@Suite(.serialized)
struct SyncEngineTests {
    // MARK: Test 1

    @Test
    func `sync all calls batch upsert for all 10 types`() async throws {
        let sut = try makeSUT(seedRecords: allTenTypes())
        await sut.engine.syncAllForActiveZone()

        #expect(try remainingCount(FamilyCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(ProfileCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(QuestCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(QuestTemplateCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(QuestCompletionCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(LedgerEntryCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(AllowancePeriodCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(AchievementCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(ProfileAchievementCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(NotificationPreferenceCache.self, in: sut.backgroundContainer) == 1)
    }

    // MARK: Test 2 — bootstrap sync purges only the resolved family's stale rows

    @Test
    func `bootstrap sync purges only the resolved family's stale rows`() async throws {
        let bgContainer = try makeContainer()
        let actor = BackgroundCacheActor(container: bgContainer)

        await actor.batchUpsertFamilies([
            seedFamily("Alpha", recordName: "fam_a"),
            seedFamily("Beta", recordName: "fam_b")
        ])

        await actor.batchUpsertProfiles([
            seedProfile(recordName: "prof1", familyRef: ref("fam_a")),
            seedProfile(recordName: "p_stale", familyRef: ref("fam_a")),
            seedProfile(recordName: "p_b", familyRef: ref("fam_b"))
        ])
        await actor.batchUpsertQuests([
            seedQuest(recordName: "quest1", familyRef: ref("fam_a")),
            seedQuest(recordName: "q_b", familyRef: ref("fam_b"))
        ])
        await actor.batchUpsertQuestTemplates([
            seedTemplate(recordName: "tpl1", familyRef: ref("fam_a")),
            seedTemplate(recordName: "t_b", familyRef: ref("fam_b"))
        ])
        await actor.batchUpsertQuestCompletions([
            seedCompletion(recordName: "comp1", familyRef: ref("fam_a")),
            seedCompletion(recordName: "c_b", familyRef: ref("fam_b"))
        ])
        await actor.batchUpsertLedgerEntries([
            seedLedger(recordName: "ledger1", familyRef: ref("fam_a")),
            seedLedger(recordName: "l_b", familyRef: ref("fam_b"))
        ])
        await actor.batchUpsertAllowancePeriods([
            seedAllowance(recordName: "allow1", familyRef: ref("fam_a")),
            seedAllowance(recordName: "ap_b", familyRef: ref("fam_b"))
        ])
        await actor.batchUpsertAchievements([
            seedAchievement(recordName: "ach1", familyRef: ref("fam_a")),
            seedAchievement(recordName: "ach_b", familyRef: ref("fam_b"))
        ])
        await actor.batchUpsertProfileAchievements([
            seedProfileAchievement(recordName: "pa1", familyRef: ref("fam_a")),
            seedProfileAchievement(recordName: "pa_b", familyRef: ref("fam_b"))
        ])
        await actor.batchUpsertNotificationPreferences([
            seedNotificationPref(recordName: "notif1", familyRef: ref("fam_a")),
            seedNotificationPref(recordName: "n_b", familyRef: ref("fam_b"))
        ])

        #expect(try remainingCount(FamilyCache.self, in: bgContainer) == 2)
        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 3)

        let zoneID = CKRecordZone.ID(zoneName: "fam_a", ownerName: "TestOwner")
        let sut = try makeSUT(
            seedRecords: allTenTypes(familyRef: ref("fam_a"), familyRecordName: "fam_a"),
            zoneID: zoneID,
            existingBgContainer: bgContainer
        )

        await sut.engine.syncAllForActiveZone()

        #expect(try remainingCount(FamilyCache.self, in: bgContainer) == 1)
        let families = try fetchAll(FamilyCache.self, in: bgContainer)
        #expect(families.first?.recordName == "fam_a")

        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 2)
        let profiles = try fetchAll(ProfileCache.self, in: bgContainer)
        let profileNames = Set(profiles.map(\.recordName))
        #expect(profileNames.contains("prof1"))
        #expect(profileNames.contains("p_b"))
        #expect(!profileNames.contains("p_stale"))

        #expect(try remainingCount(QuestCache.self, in: bgContainer) == 2)
        #expect(try remainingCount(QuestTemplateCache.self, in: bgContainer) == 2)
        #expect(try remainingCount(QuestCompletionCache.self, in: bgContainer) == 2)
        #expect(try remainingCount(LedgerEntryCache.self, in: bgContainer) == 2)
        #expect(try remainingCount(AllowancePeriodCache.self, in: bgContainer) == 2)
        #expect(try remainingCount(AchievementCache.self, in: bgContainer) == 2)
        #expect(try remainingCount(ProfileAchievementCache.self, in: bgContainer) == 2)
        #expect(try remainingCount(NotificationPreferenceCache.self, in: bgContainer) == 2)
    }

    // MARK: Test 3 — families get purged

    @Test
    func `sync all purges families`() async throws {
        let bgContainer = try makeContainer()
        let actor = BackgroundCacheActor(container: bgContainer)

        await actor.batchUpsertFamilies([
            seedFamily("Alpha", recordName: "fam_a"),
            seedFamily("Beta", recordName: "fam_b")
        ])
        #expect(try remainingCount(FamilyCache.self, in: bgContainer) == 2)

        let sut = try makeSUT(
            seedRecords: [seedFamily("Alpha", recordName: "fam_a")],
            existingBgContainer: bgContainer
        )

        await sut.engine.syncAllForActiveZone()

        #expect(try remainingCount(FamilyCache.self, in: bgContainer) == 1)
        let remaining = try fetchAll(FamilyCache.self, in: bgContainer)
        #expect(remaining.first?.recordName == "fam_a")
    }

    // MARK: Test 4 — scoped purge protects other families' notification preferences

    @Test
    func `sync all purges only resolved family's stale notification preferences`() async throws {
        let bgContainer = try makeContainer()
        let actor = BackgroundCacheActor(container: bgContainer)

        await actor.batchUpsertNotificationPreferences([
            seedNotificationPref(recordName: "np_a", familyRef: ref("fam_a")),
            seedNotificationPref(recordName: "np_stale", familyRef: ref("fam_a")),
            seedNotificationPref(recordName: "np_b", familyRef: ref("fam_b"))
        ])
        #expect(try remainingCount(NotificationPreferenceCache.self, in: bgContainer) == 3)

        let zoneID = CKRecordZone.ID(zoneName: "fam_a", ownerName: "TestOwner")
        let sut = try makeSUT(
            seedRecords: [seedNotificationPref(recordName: "np_a", familyRef: ref("fam_a"))],
            zoneID: zoneID,
            existingBgContainer: bgContainer
        )

        await sut.engine.syncAllForActiveZone()

        #expect(try remainingCount(NotificationPreferenceCache.self, in: bgContainer) == 2)
        let remaining = try fetchAll(NotificationPreferenceCache.self, in: bgContainer)
        let names = Set(remaining.map(\.recordName))
        #expect(names.contains("np_a"))
        #expect(names.contains("np_b"))
        #expect(!names.contains("np_stale"))
    }

    // MARK: Test 5

    @Test
    func `sync all handles empty zone`() async throws {
        let sut = try makeSUT(seedRecords: [])

        await sut.engine.syncAllForActiveZone()

        #expect(try remainingCount(FamilyCache.self, in: sut.backgroundContainer) == 0)
        #expect(try remainingCount(ProfileCache.self, in: sut.backgroundContainer) == 0)
        #expect(try remainingCount(QuestCache.self, in: sut.backgroundContainer) == 0)
        #expect(try remainingCount(NotificationPreferenceCache.self, in: sut.backgroundContainer) == 0)
    }

    // MARK: Test 6

    @Test
    func `incremental sync persists token after completion`() async throws {
        let sut = try makeSUT(seedRecords: allTenTypes())

        let zoneID = sut.cloudKit.resolvedZoneID
        let dbLabel = sut.cloudKit.activeIsOwner ? "private" : "shared"
        let tokenKey = "ck_change_token.\(zoneID.zoneName).\(dbLabel)"
        UserDefaults.standard.removeObject(forKey: tokenKey)

        await sut.engine.incrementalSync()

        #expect(try remainingCount(FamilyCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(ProfileCache.self, in: sut.backgroundContainer) == 1)

        #expect(sut.engine.lastSyncedAt != nil)
    }

    // MARK: Test 7 — incrementalSync propagates familyRecordName

    @Test
    func `incremental sync passes family record name to sync all fallback`() async throws {
        let bgContainer = try makeContainer()
        let actor = BackgroundCacheActor(container: bgContainer)

        await actor.batchUpsertProfiles([
            seedProfile(recordName: "p_a", familyRef: ref("fam_a")),
            seedProfile(recordName: "p_b", familyRef: ref("fam_b"))
        ])
        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 2)

        let sut = try makeSUT(
            seedRecords: [seedProfile(recordName: "p_a", familyRef: ref("fam_a"))],
            existingBgContainer: bgContainer
        )

        let dbLabel = sut.cloudKit.activeIsOwner ? "private" : "shared"
        let tokenKey = "ck_change_token.\(sut.cloudKit.resolvedZoneID.zoneName).\(dbLabel)"
        UserDefaults.standard.removeObject(forKey: tokenKey)

        await sut.engine.incrementalSync(familyRecordName: "fam_a")

        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 2)

        let remaining = try fetchAll(ProfileCache.self, in: bgContainer)
        let recordNames = Set(remaining.map(\.recordName))
        #expect(recordNames.contains("p_a"))
        #expect(recordNames.contains("p_b"))

        #expect(sut.engine.lastSyncedAt != nil)
    }

    // MARK: Test 8 — concurrency

    @Test
    func `incremental sync handles more coming recursively`() async throws {
        let sut = try makeSUT(seedRecords: allTenTypes())

        async let first = sut.engine.syncAllForActiveZone()
        async let second = sut.engine.syncAllForActiveZone()
        await first
        await second

        try await Task.sleep(for: .milliseconds(500))

        #expect(sut.engine.isSyncing == false)
        #expect(sut.engine.lastSyncedAt != nil)
    }

    // MARK: Test 9 — clean sync notification

    @Test
    func `sync did complete posts notification on success`() async throws {
        let sut = try makeSUT(seedRecords: allTenTypes())

        let box = SyncResultBox()

        let observer = NotificationCenter.default.addObserver(
            forName: .syncDidComplete,
            object: sut.engine,
            queue: .main
        ) { notification in
            box.receivedNotification = true
            box.receivedErrors = notification.userInfo?["errors"] as? [String]
        }

        await sut.engine.syncAllForActiveZone()

        await Task.yield()

        #expect(box.receivedNotification == true)
        #expect(box.receivedErrors == nil)

        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: Test 10 — notification carries errors

    @Test
    func `sync did complete posts notification on partial failure`() async throws {
        let sut = try makeSUT(seedRecords: [
            BrokenRecord(),
            seedProfile(),
            seedQuest(),
            seedTemplate(),
            seedCompletion(),
            seedLedger(),
            seedAllowance(),
            seedAchievement(),
            seedProfileAchievement(),
            seedNotificationPref()
        ])

        let box = SyncResultBox()

        let observer = NotificationCenter.default.addObserver(
            forName: .syncDidComplete,
            object: sut.engine,
            queue: .main
        ) { notification in
            box.receivedNotification = true
            box.receivedErrors = notification.userInfo?["errors"] as? [String]
        }

        await sut.engine.syncAllForActiveZone()
        await Task.yield()

        #expect(box.receivedNotification == true)
        #expect(box.receivedErrors != nil)
        #expect(box.receivedErrors?.isEmpty == false)

        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: Test 11 — clearAll before resync

    @Test
    func `zone reset purges before resync`() async throws {
        let sut = try makeSUT(seedRecords: allTenTypes())

        let staleCtx = try ModelContext(#require(sut.cacheService.container))
        staleCtx.insert(FamilyCache(
            recordName: "stale_family",
            name: "Stale Guild",
            createdByRecordName: "stale_user",
            createdAt: Date.distantPast,
            payoutPolicy: "perQuest"
        ))
        try staleCtx.save()

        #expect(try remainingCount(FamilyCache.self, in: #require(sut.cacheService.container)) == 1)
        #expect(try remainingCount(FamilyCache.self, in: sut.backgroundContainer) == 0)

        let box = SyncResultBox()
        let observer = NotificationCenter.default.addObserver(
            forName: .syncDidComplete,
            object: sut.engine,
            queue: .main
        ) { _ in
            box.receivedNotification = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        sut.coordinator.notifyZoneReset()

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !box.receivedNotification, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(box.receivedNotification == true)

        #expect(try remainingCount(FamilyCache.self, in: #require(sut.cacheService.container)) == 0)
        #expect(try remainingCount(FamilyCache.self, in: sut.backgroundContainer) == 1)
        #expect(sut.engine.lastSyncedAt != nil)
    }

    // MARK: Test 12 — tokenKey scopes per database

    @Test
    func `tokenKey scopes correctly for shared vs private databases`() throws {
        let sut = try makeSUT(seedRecords: [])

        let zoneID = CKRecordZone.ID(zoneName: "FamilyZone", ownerName: "TestOwner")

        let privateKey = sut.engine.tokenKey(for: zoneID, isShared: false)
        let sharedKey = sut.engine.tokenKey(for: zoneID, isShared: true)

        #expect(privateKey.contains("FamilyZone"))
        #expect(sharedKey.contains("FamilyZone"))

        #expect(privateKey != sharedKey)
        #expect(privateKey.hasSuffix(".private"))
        #expect(sharedKey.hasSuffix(".shared"))
    }

    // MARK: Test 13 — ParsedRecord maps correctly

    @Test
    func `parsedRecord cachedRecordType maps correctly`() {
        // parseFailure should return nil
        let failure = ParsedRecord.parseFailure(recordType: "Unknown", recordName: "test")
        #expect(failure.cachedRecordType == nil)
    }
}
