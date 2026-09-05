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
            family: familyRef,
            id: CKRecord.ID(recordName: "test-ledger-spending", zoneID: zoneID)
        )
        #expect(spending.amount < 0)
        #expect(spending.description == "Bought Toy Sword")

        let bonus = LedgerEntry(
            profile: profileRef,
            amount: 5.00,
            description: "Loot Drop Bonus",
            date: Date(),
            source: "manual",
            family: familyRef,
            id: CKRecord.ID(recordName: "test-ledger-bonus", zoneID: zoneID)
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

    // MARK: - Schema V8 round-trips

    @Test
    func `goal record round-trip preserves every field`() throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let profileRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none)
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let createdAt = Date(timeIntervalSince1970: 1_750_000_000)
        let completedAt = Date(timeIntervalSince1970: 1_750_100_000)

        let goal = Goal(
            profile: profileRef,
            family: familyRef,
            bucketKind: .shortTermSave,
            name: "New Bike",
            category: "Ride",
            emojiIcon: "🚲",
            targetAmountPennies: 25000,
            createdAt: createdAt,
            completedAt: completedAt,
            isArchived: true,
            id: CKRecord.ID(recordName: "goal1", zoneID: zoneID)
        )

        let decoded = try Goal(record: goal.toRecord())

        #expect(decoded.id == goal.id)
        #expect(decoded.profile == profileRef)
        #expect(decoded.family == familyRef)
        #expect(decoded.bucketKind == BucketKind.shortTermSave.rawValue)
        #expect(decoded.name == "New Bike")
        #expect(decoded.category == "Ride")
        #expect(decoded.emojiIcon == "🚲")
        #expect(decoded.targetAmountPennies == 25000)
        #expect(decoded.createdAt == createdAt)
        #expect(decoded.completedAt == completedAt)
        #expect(decoded.isArchived == true)
    }

    @Test
    func `goal record round-trip preserves unset optional fields`() throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")

        let goal = Goal(
            profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none),
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none),
            bucketKind: .longTermSave,
            name: "Rainy Day",
            targetAmountPennies: 10000,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            id: CKRecord.ID(recordName: "goal2", zoneID: zoneID)
        )

        let decoded = try Goal(record: goal.toRecord())

        #expect(decoded.category == nil)
        #expect(decoded.emojiIcon == nil)
        #expect(decoded.completedAt == nil)
        #expect(decoded.isArchived == false)
        #expect(decoded.bucketKind == BucketKind.longTermSave.rawValue)
    }

    @Test
    func `ledgerEntry bucket attribution fields round-trip through record`() throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let profileRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none)
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let date = Date(timeIntervalSince1970: 1_750_000_000)

        // Transfer entries carry from/to and no single bucket attribution.
        let transfer = LedgerEntry(
            profile: profileRef,
            amount: -5.00,
            description: "Moved savings",
            date: date,
            source: "transfer",
            fromBucket: BucketKind.spend.rawValue,
            toBucket: BucketKind.shortTermSave.rawValue,
            family: familyRef,
            id: CKRecord.ID(recordName: "led-t1", zoneID: zoneID)
        )

        let decodedTransfer = try LedgerEntry(record: transfer.toRecord())
        #expect(decodedTransfer.bucketKind == nil)
        #expect(decodedTransfer.fromBucket == BucketKind.spend.rawValue)
        #expect(decodedTransfer.toBucket == BucketKind.shortTermSave.rawValue)

        // Interest/match entries credit exactly one bucket.
        let interest = LedgerEntry(
            profile: profileRef,
            amount: 1.25,
            description: "Monthly interest",
            date: date,
            source: "interest",
            bucketKind: BucketKind.shortTermSave.rawValue,
            family: familyRef,
            id: CKRecord.ID(recordName: "led-i1", zoneID: zoneID)
        )

        let decodedInterest = try LedgerEntry(record: interest.toRecord())
        #expect(decodedInterest.bucketKind == BucketKind.shortTermSave.rawValue)
        #expect(decodedInterest.fromBucket == nil)
        #expect(decodedInterest.toBucket == nil)

        // Legacy pre-bucket rows decode with all three fields nil rather than failing.
        let legacy = LedgerEntry(
            profile: profileRef,
            amount: 12.50,
            description: "Old payout",
            date: date,
            source: "manual",
            family: familyRef,
            id: CKRecord.ID(recordName: "led-l1", zoneID: zoneID)
        )

        let decodedLegacy = try LedgerEntry(record: legacy.toRecord())
        #expect(decodedLegacy.bucketKind == nil)
        #expect(decodedLegacy.fromBucket == nil)
        #expect(decodedLegacy.toBucket == nil)
    }

    @Test
    func `quest claim fields round-trip through record and stay nil for board quests`() throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let templateRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "tpl1", zoneID: zoneID), action: .none)
        let heroRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none)
        let creatorRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "parent1", zoneID: zoneID), action: .none)
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let weekOf = Date(timeIntervalSince1970: 1_749_950_000)
        let claimedAt = Date(timeIntervalSince1970: 1_750_010_000)

        let claimed = Quest(
            template: templateRef,
            assignee: heroRef,
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            weekOf: weekOf,
            createdBy: creatorRef,
            family: familyRef,
            claimedByProfileRecordName: "hero9",
            claimedAt: claimedAt,
            id: CKRecord.ID(recordName: "q-claimed", zoneID: zoneID)
        )

        let decodedClaimed = try Quest(record: claimed.toRecord())
        #expect(decodedClaimed.claimedByProfileRecordName == "hero9")
        #expect(decodedClaimed.claimedAt == claimedAt)

        let onBoard = Quest(
            template: templateRef,
            assignee: heroRef,
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            weekOf: weekOf,
            createdBy: creatorRef,
            family: familyRef,
            id: CKRecord.ID(recordName: "q-board", zoneID: zoneID)
        )

        let decodedBoard = try Quest(record: onBoard.toRecord())
        #expect(decodedBoard.claimedByProfileRecordName == nil)
        #expect(decodedBoard.claimedAt == nil)
    }

    @Test
    func `profile savings config and avatarEmoji round-trip through record`() throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)

        let profile = Profile(
            displayName: "Saver",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "user1"),
            family: familyRef,
            avatarEmoji: "🦊",
            splitPercentSpend: 50,
            splitPercentShort: 30,
            splitPercentLong: 20,
            interestEnabled: true,
            interestBucket: BucketKind.longTermSave.rawValue,
            interestRateBps: 250,
            interestIsCompound: true,
            matchEnabled: true,
            matchRateBps: 100,
            matchMonthlyCapPennies: 50000,
            id: CKRecord.ID(recordName: "hero-saver", zoneID: zoneID)
        )

        let decoded = try Profile(record: profile.toRecord())

        #expect(decoded.avatarEmoji == "🦊")
        #expect(decoded.splitPercentSpend == 50)
        #expect(decoded.splitPercentShort == 30)
        #expect(decoded.splitPercentLong == 20)
        #expect(decoded.interestEnabled == true)
        #expect(decoded.interestBucket == BucketKind.longTermSave.rawValue)
        #expect(decoded.interestRateBps == 250)
        #expect(decoded.interestIsCompound == true)
        #expect(decoded.matchEnabled == true)
        #expect(decoded.matchRateBps == 100)
        #expect(decoded.matchMonthlyCapPennies == 50000)
    }

    @Test
    func `profile record without savings fields decodes fail-safe defaults`() throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)

        // Hand-build a legacy record carrying only the mandatory fields so we
        // verify decoding defaults rather than what toRecord() happens to stamp.
        let legacyRecord = CKRecord(
            recordType: Profile.recordType,
            recordID: CKRecord.ID(recordName: "hero-legacy", zoneID: zoneID)
        )
        legacyRecord["displayName"] = "Old Hero" as CKRecordValue
        legacyRecord["role"] = UserRole.hero.rawValue as CKRecordValue
        legacyRecord["xp"] = 120 as CKRecordValue
        legacyRecord["level"] = 3 as CKRecordValue
        legacyRecord["iCloudUserID"] = "user1" as CKRecordValue
        legacyRecord["family"] = familyRef

        let decoded = try Profile(record: legacyRecord)

        #expect(decoded.avatarEmoji == nil)
        #expect(decoded.splitPercentSpend == 100)
        #expect(decoded.splitPercentShort == 0)
        #expect(decoded.splitPercentLong == 0)
        #expect(decoded.interestEnabled == false)
        #expect(decoded.interestBucket == nil)
        #expect(decoded.interestRateBps == 0)
        #expect(decoded.interestIsCompound == false)
        #expect(decoded.matchEnabled == false)
        #expect(decoded.matchRateBps == 0)
        #expect(decoded.matchMonthlyCapPennies == nil)
    }
}
