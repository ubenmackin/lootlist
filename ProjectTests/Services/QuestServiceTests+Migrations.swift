//
//  QuestServiceTests+Migrations.swift
//  LootList
//
//  Created by Ben Mackin on 8/05/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

// MARK: - Data Migrations

extension QuestServiceTests {
    @Test
    func `questNameBackfillV1 saves quests with missing names to CloudKit`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )

        let templateID = CKRecord.ID(recordName: "tmpl1", zoneID: zoneID)
        let templateRef = CKRecord.Reference(recordID: templateID, action: .none)
        let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)

        // Seed template with a known name.
        let template = QuestTemplate(
            name: "Clean Room",
            description: "Tidy up",
            defaultGold: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            createdBy: familyRef,
            family: familyRef,
            id: templateID
        )

        // Seed quest with nil name.
        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none
            ),
            goldReward: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: WeekMath.mondayOfWeek(for: Date()),
            createdBy: familyRef,
            family: familyRef,
            name: nil,
            id: questID
        )

        cloudKit.seedMockRecords([template, quest])

        // Act — run the migration step directly.
        let step = DataMigrationsCoordinator.questNameBackfillV1(cloudKit: cloudKit)
        try await step.run()

        let saved = try await cloudKit.fetch(Quest.self, id: questID)
        #expect(saved.name == "Clean Room",
                "Migration must backfill nil quest names from the template")
    }

    @Test
    func `questNameBackfillV1 is idempotent on already-backfilled store`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )

        let templateID = CKRecord.ID(recordName: "tmpl1", zoneID: zoneID)
        let templateRef = CKRecord.Reference(recordID: templateID, action: .none)
        let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)

        let template = QuestTemplate(
            name: "Clean Room",
            description: "Tidy up",
            defaultGold: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            createdBy: familyRef,
            family: familyRef,
            id: templateID
        )

        // Quest already has a name — migration should skip it.
        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none
            ),
            goldReward: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: WeekMath.mondayOfWeek(for: Date()),
            createdBy: familyRef,
            family: familyRef,
            name: "Already Named",
            id: questID
        )

        cloudKit.seedMockRecords([template, quest])

        // Act — run migration; should be a no-op.
        let step = DataMigrationsCoordinator.questNameBackfillV1(cloudKit: cloudKit)
        try await step.run()

        let fetched = try await cloudKit.fetch(Quest.self, id: questID)
        #expect(fetched.name == "Already Named",
                "Migration must not overwrite existing names")
    }
}
