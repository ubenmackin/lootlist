import CloudKit
import Foundation
@testable import LootList
import Testing

struct CloudKitModelTests {
    @Test
    func `profile initialization and defaults`() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let userID = CKRecord.ID(recordName: "user1", zoneID: zoneID)

        let profile = Profile(
            displayName: "Test Hero",
            avatarClass: .rogue,
            avatarPresetID: "rogue_01",
            role: .hero,
            iCloudUserID: userID,
            family: familyRef
        )

        #expect(profile.displayName == "Test Hero")
        #expect(profile.role == .hero)
        #expect(profile.avatarClass == .rogue)
        #expect(profile.level == 1)
        #expect(profile.xp == 0)
    }

    @Test
    func `family initialization and payout policy default`() {
        let userID = CKRecord.ID(recordName: "user1")
        let family = Family(name: "Dragons", createdBy: userID)
        #expect(family.name == "Dragons")
        #expect(family.payoutPolicy == .perQuest)
    }

    @Test
    func `questTemplate initialization`() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let creatorRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "parent1", zoneID: zoneID), action: .none)

        let template = QuestTemplate(
            name: "Clean Room",
            description: "Tidy up your lair",
            defaultGold: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            createdBy: creatorRef,
            family: familyRef
        )

        #expect(template.name == "Clean Room")
        #expect(template.defaultGold == 5.0)
        #expect(template.xpReward == 50)
        #expect(template.scheduleType == .weeklyFlexible)
        #expect(template.approvalMode == .autoApprove)
    }

    @Test
    func `ledgerEntry spending vs earnings amount logic`() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let profileRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none)
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)

        let spending = LedgerEntry(
            profile: profileRef,
            amount: -12.50,
            description: "Bought Toy Sword",
            date: Date(),
            source: "manual",
            family: familyRef
        )
        #expect(spending.amount < 0)
        #expect(spending.description == "Bought Toy Sword")

        let bonus = LedgerEntry(
            profile: profileRef,
            amount: 5.00,
            description: "Loot Drop Bonus",
            date: Date(),
            source: "manual",
            family: familyRef
        )
        #expect(bonus.amount > 0)
    }
}
