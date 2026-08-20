//
//  CloudKitModelTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

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
        #expect(profile.effectiveClassDisplay == "Rogue")
    }

    @Test
    func `profile optional avatar and role fallback`() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let userID = CKRecord.ID(recordName: "user1", zoneID: zoneID)

        let profileHero = Profile(
            displayName: "No Class Hero",
            role: .hero,
            iCloudUserID: userID,
            family: familyRef
        )

        #expect(profileHero.avatarClass == nil)
        #expect(profileHero.avatarPresetID == nil)
        #expect(profileHero.effectiveClassDisplay == "Child")

        let profileParent = Profile(
            displayName: "No Class Parent",
            role: .guildMaster,
            iCloudUserID: userID,
            family: familyRef
        )

        #expect(profileParent.avatarClass == nil)
        #expect(profileParent.effectiveClassDisplay == "Parent")
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
    func `weekly flexible template omits empty specificDays from record`() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let creatorRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "parent1", zoneID: zoneID), action: .none)

        let template = QuestTemplate(
            name: "Weekly Chore",
            description: "Do it any day this week",
            defaultGold: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            specificDays: [],
            approvalMode: .autoApprove,
            createdBy: creatorRef,
            family: familyRef
        )

        let record = template.toRecord()

        // CloudKit rejects initializing a new field with an empty list, so a
        // weekly-flexible template must not carry a `specificDays` key.
        #expect(record["specificDays"] == nil)
        #expect(record.allKeys().contains("specificDays") == false)
    }

    @Test
    func `specificDays schedule round-trips through record`() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let creatorRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "parent1", zoneID: zoneID), action: .none)

        let template = QuestTemplate(
            name: "Band Practice",
            description: "Play any of the listed days",
            defaultGold: 3.0,
            xpReward: 30,
            scheduleType: .specificDays,
            specificDays: ["monday", "wednesday", "friday"],
            approvalMode: .autoApprove,
            createdBy: creatorRef,
            family: familyRef
        )

        let record = template.toRecord()

        #expect(record["specificDays"] as? [String] == ["monday", "wednesday", "friday"])

        let decoded = try? QuestTemplate(record: record)
        #expect(decoded?.specificDays == ["monday", "wednesday", "friday"])
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

    @Test
    func `questCompletion decoding propagates missingField and typeMismatch errors`() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let recordID = CKRecord.ID(recordName: "qc1", zoneID: zoneID)
        let questRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "q1", zoneID: zoneID), action: .none)
        let heroRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none)
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)

        // 1. Missing verificationStatus field throws missingField
        let missingFieldRecord = CKRecord(recordType: QuestCompletion.recordType, recordID: recordID)
        missingFieldRecord["quest"] = questRef
        missingFieldRecord["completedBy"] = heroRef
        missingFieldRecord["completedDate"] = Date()
        missingFieldRecord["weekOf"] = Date()
        missingFieldRecord["family"] = familyRef

        #expect(throws: CKDecodingError.self) {
            _ = try QuestCompletion(record: missingFieldRecord)
        }

        // 2. Wrong type for verificationStatus throws typeMismatch
        let typeMismatchRecord = CKRecord(recordType: QuestCompletion.recordType, recordID: recordID)
        typeMismatchRecord["quest"] = questRef
        typeMismatchRecord["completedBy"] = heroRef
        typeMismatchRecord["completedDate"] = Date()
        typeMismatchRecord["weekOf"] = Date()
        typeMismatchRecord["family"] = familyRef
        typeMismatchRecord["verificationStatus"] = 12345 // Int instead of String

        #expect(throws: CKDecodingError.self) {
            _ = try QuestCompletion(record: typeMismatchRecord)
        }

        // 3. Valid record decodes successfully
        let validRecord = CKRecord(recordType: QuestCompletion.recordType, recordID: recordID)
        validRecord["quest"] = questRef
        validRecord["completedBy"] = heroRef
        validRecord["completedDate"] = Date()
        validRecord["weekOf"] = Date()
        validRecord["family"] = familyRef
        validRecord["verificationStatus"] = "verified"

        let decoded = try? QuestCompletion(record: validRecord)
        #expect(decoded != nil)
        #expect(decoded?.verificationStatus == .verified)
    }
}
