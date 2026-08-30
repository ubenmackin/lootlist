//
//  RecordBridgeTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/27/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData
import Testing

@MainActor
struct RecordBridgeTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    private func ref(_ name: String) -> CKRecord.Reference {
        CKRecord.Reference(recordID: CKRecord.ID(recordName: name, zoneID: zoneID), action: .none)
    }

    private func id(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    // MARK: - Managed keys exhaustiveness

    @Test
    func `managedFieldKeys equals toRecord keys for non-nil fields across all record types`() {
        verifyFamilyManagedKeys()
        verifyProfileManagedKeys()
        verifyQuestTemplateManagedKeys()
        verifyQuestManagedKeys()
        verifyQuestCompletionManagedKeys()
        verifyAllowancePeriodManagedKeys()
        verifyLedgerEntryManagedKeys()
        verifyAchievementManagedKeys()
        verifyProfileAchievementManagedKeys()
        verifyNotificationPreferenceManagedKeys()
        verifyRewardEventManagedKeys()
        verifyGemLedgerManagedKeys()
        verifyGoalManagedKeys()
    }

    private func verifyFamilyManagedKeys() {
        let family = Family(name: "Dragons", createdBy: id("user1"), payoutPolicy: .perQuest, payoutDay: .sunday, id: id("fam1"))
        let actual = Set(family.toRecord().allKeys())
        let expected = Family.managedFieldKeys
        #expect(expected == actual, "Family managedFieldKeys mismatch: missing \(expected.subtracting(actual).sorted()) extra \(actual.subtracting(expected).sorted())")
    }

    private func verifyProfileManagedKeys() {
        var profile = Profile(
            displayName: "Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            customAvatarImageData: Data([0x01, 0x02]),
            role: .hero,
            iCloudUserID: id("icloud1"),
            family: ref("fam1"),
            payoutPolicy: .perQuest,
            payoutDay: .monday,
            gems: 5,
            streakShields: 1,
            mascotCompanion: "fox",
            ownedEquipment: ["sword"],
            equippedItems: ["sword"],
            dailyLoginLastClaimDay: "2026-01-01",
            dailyLoginCycleDay: 2,
            dailyLoginStreakDays: 3,
            claimedBonusObjectives: ["obj1"],
            journeyMapLastSeenLevel: 2,
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
            id: id("hero1")
        )
        profile.xp = 120
        profile.level = 3
        profile.isActive = true
        let actual = Set(profile.toRecord().allKeys())
        let expected = Profile.managedFieldKeys
        #expect(expected == actual, "Profile managedFieldKeys mismatch: missing \(expected.subtracting(actual).sorted()) extra \(actual.subtracting(expected).sorted())")
    }

    private func verifyQuestTemplateManagedKeys() {
        let template = QuestTemplate(
            name: "Tidy Room",
            description: "Tidy up",
            defaultGold: 5.0,
            xpReward: 50,
            scheduleType: .specificDays,
            specificDays: ["Mon"],
            targetCount: 2,
            isAllOrNothing: true,
            approvalMode: .parentVerify,
            createdBy: ref("creator1"),
            family: ref("fam1"),
            isActive: true,
            id: id("tpl1")
        )
        let actual = Set(template.toRecord().allKeys())
        let expected = QuestTemplate.managedFieldKeys
        #expect(expected == actual, "QuestTemplate managedFieldKeys mismatch: missing \(expected.subtracting(actual).sorted()) extra \(actual.subtracting(expected).sorted())")
    }

    private func verifyQuestManagedKeys() {
        let quest = Quest(
            template: ref("tpl1"),
            assignee: ref("hero1"),
            goldReward: 10.0,
            xpReward: 100,
            scheduleType: .weeklyFlexible,
            targetCount: 2,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: Date(timeIntervalSince1970: 1_750_000_000),
            createdBy: ref("creator1"),
            family: ref("fam1"),
            name: "Quest Name",
            descriptionText: "Do the thing",
            xpBanked: 10,
            claimedByProfileRecordName: "hero2",
            claimedAt: Date(timeIntervalSince1970: 1_750_010_000),
            id: id("quest1")
        )
        let actual = Set(quest.toRecord().allKeys())
        let expected = Quest.managedFieldKeys
        #expect(expected == actual, "Quest managedFieldKeys mismatch: missing \(expected.subtracting(actual).sorted()) extra \(actual.subtracting(expected).sorted())")
    }

    private func verifyQuestCompletionManagedKeys() {
        var completion = QuestCompletion(
            quest: ref("quest1"),
            completedBy: ref("hero1"),
            approvalMode: .parentVerify,
            completedDate: Date(timeIntervalSince1970: 1_750_000_000),
            weekOf: Date(timeIntervalSince1970: 1_749_950_000),
            family: ref("fam1"),
            xpCredited: 50,
            id: id("comp1")
        )
        completion.verificationStatus = .verified
        completion.verifiedBy = ref("parent1")
        completion.verifiedDate = Date(timeIntervalSince1970: 1_750_020_000)
        let actual = Set(completion.toRecord().allKeys())
        let expected = QuestCompletion.managedFieldKeys
        #expect(
            expected == actual,
            "QuestCompletion managedFieldKeys mismatch: missing \(expected.subtracting(actual).sorted()) extra \(actual.subtracting(expected).sorted())"
        )
    }

    private func verifyAllowancePeriodManagedKeys() {
        let period = AllowancePeriod(
            weekOf: Date(timeIntervalSince1970: 1_749_950_000),
            profile: ref("hero1"),
            status: .paid,
            totalEarned: 25.0,
            questsCompleted: 3,
            questsTotal: 5,
            paidDate: Date(timeIntervalSince1970: 1_750_100_000),
            paidAmount: 25.0,
            family: ref("fam1"),
            id: id("per1")
        )
        let actual = Set(period.toRecord().allKeys())
        let expected = AllowancePeriod.managedFieldKeys
        #expect(
            expected == actual,
            "AllowancePeriod managedFieldKeys mismatch: missing \(expected.subtracting(actual).sorted()) extra \(actual.subtracting(expected).sorted())"
        )
    }

    private func verifyLedgerEntryManagedKeys() {
        let entry = LedgerEntry(
            profile: ref("hero1"),
            amount: 5.0,
            description: "Bonus",
            location: "Store",
            date: Date(timeIntervalSince1970: 1_750_000_000),
            source: "transfer",
            bucketKind: BucketKind.spend.rawValue,
            fromBucket: BucketKind.spend.rawValue,
            toBucket: BucketKind.shortTermSave.rawValue,
            family: ref("fam1"),
            id: id("led1")
        )
        let actual = Set(entry.toRecord().allKeys())
        let expected = LedgerEntry.managedFieldKeys
        #expect(expected == actual, "LedgerEntry managedFieldKeys mismatch: missing \(expected.subtracting(actual).sorted()) extra \(actual.subtracting(expected).sorted())")
    }

    private func verifyAchievementManagedKeys() {
        let achievement = Achievement(
            name: "First Quest",
            description: "Complete your first quest",
            iconSystemName: "star.fill",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: ref("fam1"),
            id: id("ach1")
        )
        let actual = Set(achievement.toRecord().allKeys())
        let expected = Achievement.managedFieldKeys
        #expect(expected == actual, "Achievement managedFieldKeys mismatch: missing \(expected.subtracting(actual).sorted()) extra \(actual.subtracting(expected).sorted())")
    }

    private func verifyProfileAchievementManagedKeys() {
        let pa = ProfileAchievement(
            achievement: ref("ach1"),
            profile: ref("hero1"),
            earnedDate: Date(timeIntervalSince1970: 1_750_000_000),
            family: ref("fam1"),
            id: id("pa1")
        )
        let actual = Set(pa.toRecord().allKeys())
        let expected = ProfileAchievement.managedFieldKeys
        #expect(
            expected == actual,
            "ProfileAchievement managedFieldKeys mismatch: missing \(expected.subtracting(actual).sorted()) extra \(actual.subtracting(expected).sorted())"
        )
    }

    private func verifyNotificationPreferenceManagedKeys() {
        let pref = NotificationPreference(
            profile: ref("hero1"),
            eventType: .questCompleted,
            enabled: true,
            family: ref("fam1"),
            id: id("pref1")
        )
        let actual = Set(pref.toRecord().allKeys())
        let expected = NotificationPreference.managedFieldKeys
        #expect(
            expected == actual,
            "NotificationPreference managedFieldKeys mismatch: missing \(expected.subtracting(actual).sorted()) extra \(actual.subtracting(expected).sorted())"
        )
    }

    private func verifyRewardEventManagedKeys() {
        let event = RewardEvent(
            profile: ref("hero1"),
            questCompletion: ref("comp1"),
            xpAmount: 50,
            goldAmount: 10.0,
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            family: ref("fam1"),
            id: id("rew1")
        )
        let actual = Set(event.toRecord().allKeys())
        let expected = RewardEvent.managedFieldKeys
        #expect(expected == actual, "RewardEvent managedFieldKeys mismatch: missing \(expected.subtracting(actual).sorted()) extra \(actual.subtracting(expected).sorted())")
    }

    private func verifyGemLedgerManagedKeys() {
        let gem = GemLedger(
            profileRecordName: "hero1",
            family: ref("fam1"),
            amount: 10,
            source: "quest",
            sourceDetail: "detail",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            id: id("gem1")
        )
        let actual = Set(gem.toRecord().allKeys())
        let expected = GemLedger.managedFieldKeys
        #expect(expected == actual, "GemLedger managedFieldKeys mismatch: missing \(expected.subtracting(actual).sorted()) extra \(actual.subtracting(expected).sorted())")
    }

    private func verifyGoalManagedKeys() {
        let goal = Goal(
            profile: ref("hero1"),
            family: ref("fam1"),
            bucketKind: .shortTermSave,
            name: "New Bike",
            category: "Toys",
            emojiIcon: "🎯",
            targetAmountPennies: 5000,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            completedAt: Date(timeIntervalSince1970: 1_750_100_000),
            isArchived: false,
            targetDate: Date(timeIntervalSince1970: 1_750_200_000),
            linkURL: "https://example.com/bike",
            imageURL: "https://example.com/bike.jpg",
            id: id("goal1")
        )
        let actual = Set(goal.toRecord().allKeys())
        let expected = Goal.managedFieldKeys
        #expect(expected == actual, "Goal managedFieldKeys mismatch: missing \(expected.subtracting(actual).sorted()) extra \(actual.subtracting(expected).sorted())")
    }

    // MARK: - prepareRecord regression: Goal emojiIcon nil vs non-nil

    @Test
    func `recordBridge prepareRecord clears Goal emojiIcon when nil and preserves when non-nil`() async throws {
        let cache = try CacheService(inMemory: true)
        let familyName = "fam1"
        let goalRecordName = "goal-emoji-test"
        let goalID = id(goalRecordName)
        let identity = ScopedRecordIdentity(databaseScope: .private, zoneID: zoneID, recordID: goalID, familyRecordName: familyName)

        // Non-nil emojiIcon should appear in the prepared CKRecord
        let goalWithEmoji = Goal(
            profile: ref("hero1"),
            family: ref(familyName),
            bucketKind: .shortTermSave,
            name: "Save for bike",
            category: "Toys",
            emojiIcon: "🎯",
            targetAmountPennies: 5000,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            id: goalID
        )
        await cache.upsertGoal(goalWithEmoji)

        guard let recordWithEmoji = RecordBridge.record(for: identity, cacheService: cache) else {
            Issue.record("RecordBridge.record returned nil for Goal with emojiIcon")
            return
        }
        #expect(recordWithEmoji.allKeys().contains("emojiIcon"), "CKRecord should contain emojiIcon when Goal has non-nil emojiIcon")
        #expect((recordWithEmoji["emojiIcon"] as? String) == "🎯")

        // Nil emojiIcon should be cleared so stale server value is deleted
        var goalWithoutEmoji = goalWithEmoji
        goalWithoutEmoji.emojiIcon = nil
        await cache.upsertGoal(goalWithoutEmoji)

        guard let recordWithoutEmoji = RecordBridge.record(for: identity, cacheService: cache) else {
            Issue.record("RecordBridge.record returned nil for Goal with nil emojiIcon")
            return
        }
        #expect(!recordWithoutEmoji.allKeys().contains("emojiIcon"), "CKRecord should not contain emojiIcon after Goal emojiIcon is cleared to nil")
        #expect(recordWithoutEmoji["emojiIcon"] == nil)
    }

    // MARK: - prepareRecord regression: LedgerEntry bucket attribution

    @Test
    func `recordBridge prepareRecord clears LedgerEntry bucket attribution when nil and preserves when non-nil`() async throws {
        let cache = try CacheService(inMemory: true)
        let familyName = "fam1"
        let entryRecordName = "led-bucket-test"
        let entryID = id(entryRecordName)
        let identity = ScopedRecordIdentity(databaseScope: .private, zoneID: zoneID, recordID: entryID, familyRecordName: familyName)

        // Non-nil bucket fields should appear in the prepared CKRecord
        let entryWithBuckets = LedgerEntry(
            profile: ref("hero1"),
            amount: 5.0,
            description: "Transfer",
            location: "App",
            date: Date(timeIntervalSince1970: 1_750_000_000),
            source: "transfer",
            bucketKind: BucketKind.spend.rawValue,
            fromBucket: BucketKind.spend.rawValue,
            toBucket: BucketKind.shortTermSave.rawValue,
            family: ref(familyName),
            id: entryID
        )
        await cache.upsertLedgerEntry(entryWithBuckets)

        guard let recordWithBuckets = RecordBridge.record(for: identity, cacheService: cache) else {
            Issue.record("RecordBridge.record returned nil for LedgerEntry with bucket fields")
            return
        }
        #expect(recordWithBuckets.allKeys().contains("bucketKind"), "CKRecord should contain bucketKind when LedgerEntry has non-nil bucketKind")
        #expect((recordWithBuckets["bucketKind"] as? String) == BucketKind.spend.rawValue)
        #expect(recordWithBuckets.allKeys().contains("fromBucket"), "CKRecord should contain fromBucket when LedgerEntry has non-nil fromBucket")
        #expect((recordWithBuckets["fromBucket"] as? String) == BucketKind.spend.rawValue)
        #expect(recordWithBuckets.allKeys().contains("toBucket"), "CKRecord should contain toBucket when LedgerEntry has non-nil toBucket")
        #expect((recordWithBuckets["toBucket"] as? String) == BucketKind.shortTermSave.rawValue)

        // Nil bucket fields should be cleared
        var entryWithoutBuckets = entryWithBuckets
        entryWithoutBuckets.bucketKind = nil
        entryWithoutBuckets.fromBucket = nil
        entryWithoutBuckets.toBucket = nil
        await cache.upsertLedgerEntry(entryWithoutBuckets)

        guard let recordWithoutBuckets = RecordBridge.record(for: identity, cacheService: cache) else {
            Issue.record("RecordBridge.record returned nil for LedgerEntry with nil bucket fields")
            return
        }
        #expect(!recordWithoutBuckets.allKeys().contains("bucketKind"), "CKRecord should not contain bucketKind after LedgerEntry bucketKind is cleared to nil")
        #expect(recordWithoutBuckets["bucketKind"] == nil)
        #expect(!recordWithoutBuckets.allKeys().contains("fromBucket"), "CKRecord should not contain fromBucket after LedgerEntry fromBucket is cleared to nil")
        #expect(recordWithoutBuckets["fromBucket"] == nil)
        #expect(!recordWithoutBuckets.allKeys().contains("toBucket"), "CKRecord should not contain toBucket after LedgerEntry toBucket is cleared to nil")
        #expect(recordWithoutBuckets["toBucket"] == nil)
    }
}
