//
//  DataMigrationsCoordinatorTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/14/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct DataMigrationsCoordinatorTests {
    @Test
    func `runPendingMigrations scopes keys by account and family`() async throws {
        let suite = "MigrationTests_Scoped_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let coordinator = DataMigrationsCoordinator(defaults: defaults)
        var runCount = 0
        coordinator.register(DataMigrationsCoordinator.MigrationStep(id: "ScopedStep", version: 1) {
            runCount += 1
        })

        let accountID = "user123"
        let familyRecordName = "family456"

        await coordinator.runPendingMigrations(accountID: accountID, familyRecordName: familyRecordName)

        #expect(runCount == 1)
        let expectedKey = "migration.\(accountID).\(familyRecordName).ScopedStep.v1.complete"
        #expect(defaults.bool(forKey: expectedKey) == true)

        // Running again with same scoped keys should skip
        await coordinator.runPendingMigrations(accountID: accountID, familyRecordName: familyRecordName)
        #expect(runCount == 1)

        // Running with a different family should run
        await coordinator.runPendingMigrations(accountID: accountID, familyRecordName: "differentFamily")
        #expect(runCount == 2)

        defaults.removePersistentDomain(forName: suite)
    }

    @Test
    func `questNameBackfillV1 reconciles missing template with fallback title instead of failing`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let missingTemplateID = CKRecord.ID(recordName: "missing-tmpl", zoneID: zoneID)
        let templateRef = CKRecord.Reference(recordID: missingTemplateID, action: .none)

        let questID = CKRecord.ID(recordName: "quest-without-tmpl", zoneID: zoneID)
        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none),
            goldReward: 1000,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            weekOf: Date(),
            createdBy: familyRef,
            family: familyRef,
            name: nil,
            id: questID
        )
        cloudKit.seedMockRecords([quest])

        let step = DataMigrationsCoordinator.questNameBackfillV1(cloudKit: cloudKit)
        try await step.run()

        let saved = try await cloudKit.fetch(Quest.self, id: questID)
        #expect(saved.name == "Quest", "Missing template should be reconciled with fallback title rather than failing in an infinite retry loop")
    }

    @Test
    func `questNameBackfillV1 throws error on save failure so migration is retried`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let templateID = CKRecord.ID(recordName: "tmpl1", zoneID: zoneID)
        let templateRef = CKRecord.Reference(recordID: templateID, action: .none)

        let template = QuestTemplate(
            name: "Sweep Floor",
            description: "Sweep",
            defaultGold: 500,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            createdBy: familyRef,
            family: familyRef,
            id: templateID
        )

        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none),
            goldReward: 1000,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            weekOf: Date(),
            createdBy: familyRef,
            family: familyRef,
            name: nil,
            id: CKRecord.ID(recordName: "quest-save-fail", zoneID: zoneID)
        )
        cloudKit.seedMockRecords([template, quest])
        cloudKit.saveError = CloudKitServiceError.networkUnavailable

        let step = DataMigrationsCoordinator.questNameBackfillV1(cloudKit: cloudKit)
        await #expect(throws: Error.self) {
            try await step.run()
        }
    }

    @Test
    func `achievementMigrationV1 migrates legacy UUID achievements to canonical deterministic IDs`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let legacyUUID = UUID().uuidString
        let legacyAchievement = Achievement(
            id: CKRecord.ID(recordName: legacyUUID, zoneID: zoneID),
            name: "First Steps",
            description: "Complete your first quest",
            iconSystemName: "shoeprints.fill",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: familyRef
        )
        cloudKit.seedMockRecords([legacyAchievement])

        let step = DataMigrationsCoordinator.achievementMigrationV1(cloudKit: cloudKit, cacheService: cache)
        try await step.run()

        let canonicalID = CKRecord.ID(recordName: "fam1-firstQuest", zoneID: zoneID)
        let migrated = try await cloudKit.fetch(Achievement.self, id: canonicalID)
        #expect(migrated.name == "First Steps")
        #expect(cloudKit.deletedRecordIDs.contains(legacyAchievement.id))
    }

    @Test
    func `heroNotificationPreferenceBackfillV1 throws when preferences query fails`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let profile = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "user1"),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        cloudKit.seedMockRecords([profile])
        cloudKit.fetchError = CloudKitServiceError.networkUnavailable
        // WHY anchor aligned: owner scope resolves so the preferences query runs and throws.
        let appState = AppState.testState()
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.family = Family(name: "Test Guild", creatorUserRecordName: MockCloudKitService.mockUserRecordName, id: CKRecord.ID(recordName: "fam1", zoneID: zoneID))
        let ownerID = CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID)
        appState.currentProfile = Profile(displayName: "Owner", role: .guildMaster, iCloudUserID: ownerID, family: familyRef, id: ownerID)

        let step = DataMigrationsCoordinator.heroNotificationPreferenceBackfillV1(cloudKit: cloudKit, cacheService: nil, appState: appState)
        await #expect(throws: Error.self) {
            try await step.run()
        }
    }

    @Test
    func `allowancePeriodSeedV1 throws when periods query fails`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let profile = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "user1"),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        cloudKit.seedMockRecords([profile])
        cloudKit.fetchError = CloudKitServiceError.networkUnavailable

        let step = DataMigrationsCoordinator.allowancePeriodSeedV1(cloudKit: cloudKit, cacheService: nil)
        await #expect(throws: Error.self) {
            try await step.run()
        }
    }

    @Test
    func `allowancePeriodSeedV1 seeds periods only for active heroes and skips non-hero profiles`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "fam1", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let heroProfile = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "user1"),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        let parentProfile = Profile(
            displayName: "Parent",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "user2"),
            family: familyRef,
            id: CKRecord.ID(recordName: "parent1", zoneID: zoneID)
        )
        cloudKit.seedMockRecords([heroProfile, parentProfile])
        // WHY anchor aligned: owner scope resolves so the hero seed writes one period.
        let appState = AppState.testState()
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.family = Family(name: "Test Guild", creatorUserRecordName: MockCloudKitService.mockUserRecordName, id: CKRecord.ID(recordName: "fam1", zoneID: zoneID))
        let ownerID = CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID)
        appState.currentProfile = Profile(displayName: "Owner", role: .guildMaster, iCloudUserID: ownerID, family: familyRef, id: ownerID)

        let step = DataMigrationsCoordinator.allowancePeriodSeedV1(cloudKit: cloudKit, cacheService: nil, appState: appState)
        try await step.run()

        let periods = try await cloudKit.query(AllowancePeriod.self, predicate: NSPredicate(value: true), in: zoneID)
        #expect(periods.count == 1)
        #expect(periods.contains { $0.profile.recordID.recordName == "hero1" })
        #expect(!periods.contains { $0.profile.recordID.recordName == "parent1" })
    }

    @Test
    func `purgeParentAllowancePeriodsV1 purges periods belonging to parent profiles and leaves hero periods`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "fam1", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let heroProfile = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "user1"),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        let parentProfile = Profile(
            displayName: "Parent",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "user2"),
            family: familyRef,
            id: CKRecord.ID(recordName: "parent1", zoneID: zoneID)
        )
        let heroPeriod = AllowancePeriod(
            weekOf: Date(),
            profile: CKRecord.Reference(recordID: heroProfile.id, action: .none),
            questsTotal: 1,
            family: familyRef,
            id: CKRecord.ID(recordName: "period-hero1", zoneID: zoneID)
        )
        let parentPeriod = AllowancePeriod(
            weekOf: Date(),
            profile: CKRecord.Reference(recordID: parentProfile.id, action: .none),
            questsTotal: 0,
            family: familyRef,
            id: CKRecord.ID(recordName: "period-parent1", zoneID: zoneID)
        )

        cloudKit.seedMockRecords([heroProfile, parentProfile, heroPeriod, parentPeriod])
        let cache = try CacheService(inMemory: true)
        await cache.upsertAllowancePeriod(heroPeriod)
        await cache.upsertAllowancePeriod(parentPeriod)
        let spy = PurgeDeleteSpy()
        // WHY anchor aligned: owner scope resolves so the parent purge enqueues a tombstone.
        let appState = AppState.testState()
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        cloudKit.activeIsOwner = true
        appState.family = Family(name: "Test Guild", creatorUserRecordName: MockCloudKitService.mockUserRecordName, id: CKRecord.ID(recordName: "fam1", zoneID: zoneID))
        let ownerID = CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID)
        appState.currentProfile = Profile(displayName: "Owner", role: .guildMaster, iCloudUserID: ownerID, family: familyRef, id: ownerID)

        let step = DataMigrationsCoordinator.purgeParentAllowancePeriodsV1(cloudKit: cloudKit, cacheService: cache, syncCoordinator: spy, appState: appState)
        try await step.run()

        // WHY single path: engine sends the delete so no direct cloudKit.delete lands here.
        #expect(cloudKit.deletedRecordIDs.isEmpty)
        #expect(spy.deleted.contains(parentPeriod.id.recordName))
        #expect(!spy.deleted.contains(heroPeriod.id.recordName))
        // WHY family-scoped: purge invalidates only the parent row in the owning family.
        #expect(cache.fetchAllowancePeriod(recordName: parentPeriod.id.recordName, family: "fam1") == nil)
        #expect(cache.fetchAllowancePeriod(recordName: heroPeriod.id.recordName, family: "fam1") != nil)
    }

    // MARK: - Schema V8 transition

    @Test
    func `schemaV8SavingsResetMarker completes per account and family and skips reruns`() async throws {
        let suite = "MigrationTests_V8Marker_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")

        let coordinator = DataMigrationsCoordinator(defaults: defaults)
        coordinator.register(DataMigrationsCoordinator.schemaV8SavingsResetMarker(cloudKit: cloudKit))

        await coordinator.runPendingMigrations(accountID: "user123", familyRecordName: "family456")
        #expect(defaults.bool(forKey: "migration.user123.family456.SchemaV8SavingsResetMarker.v8.complete"))

        // The marker must be idempotent: a second pass for the same family is a
        // no-op and leaves the completion flag intact.
        await coordinator.runPendingMigrations(accountID: "user123", familyRecordName: "family456")
        #expect(defaults.bool(forKey: "migration.user123.family456.SchemaV8SavingsResetMarker.v8.complete"))

        // A different family scopes its own transition marker.
        await coordinator.runPendingMigrations(accountID: "user123", familyRecordName: "family789")
        #expect(defaults.bool(forKey: "migration.user123.family789.SchemaV8SavingsResetMarker.v8.complete"))
        #expect(defaults.bool(forKey: "migration.user123.family456.SchemaV8SavingsResetMarker.v8.complete"))

        defaults.removePersistentDomain(forName: suite)
    }

    @Test
    func `schemaV8SavingsResetMarker completes fail-open without an active zone`() async throws {
        // The destructive cache reset itself happens when the SwiftData container
        // opens with the V8 schema; the marker only records that the version
        // transition was observed. Failing here (e.g. before a session exists)
        // would retry forever without ever doing the real work, so it must
        // complete even with no active family zone.
        let suite = "MigrationTests_V8MarkerNoZone_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = nil

        let coordinator = DataMigrationsCoordinator(defaults: defaults)
        coordinator.register(DataMigrationsCoordinator.schemaV8SavingsResetMarker(cloudKit: cloudKit))

        await coordinator.runPendingMigrations(accountID: "user123", familyRecordName: "family456")

        #expect(defaults.bool(forKey: "migration.user123.family456.SchemaV8SavingsResetMarker.v8.complete"))

        defaults.removePersistentDomain(forName: suite)
    }
}

/// WHY spy: records engine-bound deletes without a live CKSyncEngine.
@MainActor
private final class PurgeDeleteSpy: SyncEnqueuing {
    var deleted: [String] = []
    func enqueueSave(recordID _: CKRecord.ID, isOwner _: Bool) {}
    func enqueueDelete(recordID: CKRecord.ID, isOwner _: Bool) {
        deleted.append(recordID.recordName)
    }

    func batchEnqueueSave(recordIDs _: [CKRecord.ID], isOwner _: Bool) {}
}
