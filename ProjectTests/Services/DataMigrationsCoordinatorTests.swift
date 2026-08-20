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
            goldReward: 10.0,
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
            defaultGold: 5.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            createdBy: familyRef,
            family: familyRef,
            id: templateID
        )

        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none),
            goldReward: 10.0,
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

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let profile = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "user1"),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        cloudKit.seedMockRecords([profile])
        cloudKit.queryError = CloudKitServiceError.networkUnavailable

        let step = DataMigrationsCoordinator.heroNotificationPreferenceBackfillV1(cloudKit: cloudKit, cacheService: nil)
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
        cloudKit.queryError = CloudKitServiceError.networkUnavailable

        let step = DataMigrationsCoordinator.allowancePeriodSeedV1(cloudKit: cloudKit, cacheService: nil)
        await #expect(throws: Error.self) {
            try await step.run()
        }
    }
}
