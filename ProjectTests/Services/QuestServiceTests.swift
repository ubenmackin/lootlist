//
//  QuestServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct QuestServiceTests {
    private func makeTestData() -> (CloudKitService, Profile, Profile, Family) { // swiftlint:disable:this large_tuple
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let userID = CKRecord.ID(recordName: "user1", zoneID: zoneID)

        let parent = Profile(
            displayName: "Parent GM",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: userID,
            family: familyRef
        )

        let hero = Profile(
            displayName: "Child Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: userID,
            family: familyRef
        )

        let family = Family(
            name: "Test Guild",
            createdBy: parent.id,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        return (cloudKit, parent, hero, family)
    }

    @Test
    func `quest service initialization`() {
        let (cloudKit, _, _, _) = makeTestData()
        let questService = QuestService(cloudKit: cloudKit)
        #expect(questService.cloudKitReference === cloudKit)
    }

    @Test
    func `create quest template model instantiation`() async throws {
        let (cloudKit, parent, _, family) = makeTestData()
        let questService = QuestService(cloudKit: cloudKit)

        let template = try await questService.createTemplate(
            name: "Clean Room",
            description: "Tidy up all toys",
            defaultGold: 5.0,
            xpReward: 50,
            schedule: .weeklyFlexible,
            approvalMode: .parentVerify,
            createdBy: parent,
            family: family
        )

        #expect(template.name == "Clean Room")
        #expect(template.description == "Tidy up all toys")
        #expect(template.defaultGold == 5.0)
        #expect(template.xpReward == 50)
        #expect(template.scheduleType == .weeklyFlexible)
        #expect(template.approvalMode == .parentVerify)
        #expect(template.isActive == true)
    }

    @Test
    func `quest schedule types and day properties`() {
        let specific = QuestSchedule.specificDays
        let flexible = QuestSchedule.weeklyFlexible

        #expect(specific.displayName == "Specific Days")
        #expect(flexible.displayName == "Flexible (Any Day)")
        #expect(specific.requiresSpecificDays == true)
        #expect(flexible.requiresSpecificDays == false)
    }

    @Test
    func `quest error types equatable`() {
        #expect(QuestServiceError.missingSession == QuestServiceError.missingSession)
        #expect(QuestServiceError.alreadyCompleted == QuestServiceError.alreadyCompleted)
        #expect(QuestServiceError.alreadyResolved("e1") == QuestServiceError.alreadyResolved("e1"))
        #expect(QuestServiceError.alreadyResolved("e1") != QuestServiceError.alreadyResolved("e2"))
        #expect(QuestServiceError.missingRecord("r1") == QuestServiceError.missingRecord("r1"))
    }
}
