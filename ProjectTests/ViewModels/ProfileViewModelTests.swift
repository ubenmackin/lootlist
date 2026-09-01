//
//  ProfileViewModelTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/9/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct ProfileViewModelTests {
    private struct TestHarness {
        let profile: Profile
        let zoneID: CKRecordZone.ID
        let profileName: String
        let familyName: String
    }

    private func makeHarness() -> TestHarness {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let familyID = CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let profile = Profile(
            displayName: "Test Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: heroID
        )
        return TestHarness(
            profile: profile,
            zoneID: zoneID,
            profileName: "hero1",
            familyName: "fam1"
        )
    }

    @Test
    func `recomputeCharacterFromCache computes balance strictly from ledger sum without double-counting quest logs`() {
        let test = makeHarness()
        let viewModel = ProfileViewModel()

        let currentWeek = WeekMath.weekOf(date: Date())

        let quest = QuestCache(
            recordName: "quest1",
            familyRecordName: test.familyName,
            assigneeRecordName: test.profileName,
            templateRecordName: "t1",
            weekOf: currentWeek,
            questName: "Clean Room",
            isActive: true,
            goldReward: 10.0,
            xpReward: 5,
            rarity: "common",
            scheduleType: QuestSchedule.specificDays.rawValue,
            isAllOrNothing: false,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            descriptionText: nil,
            createdByRecordName: "parent1"
        )

        let questLog = QuestCompletionCache(
            recordName: "log1",
            questRecordName: "quest1",
            familyRecordName: test.familyName,
            completerRecordName: test.profileName,
            completedDate: Date(),
            weekOf: currentWeek,
            verificationStatus: VerificationStatus.autoApproved.rawValue,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            verifiedByRecordName: nil,
            verifiedDate: nil
        )

        let questPayoutLedger = LedgerEntryCache(
            recordName: "ledger_payout",
            profileRecordName: test.profileName,
            familyRecordName: test.familyName,
            amount: 10.0,
            entryDescription: "Weekly Allowance Payout",
            location: nil,
            date: Date(),
            source: "quest"
        )

        let bonusLedger = LedgerEntryCache(
            recordName: "ledger_bonus",
            profileRecordName: test.profileName,
            familyRecordName: test.familyName,
            amount: 5.0,
            entryDescription: "Extra Loot",
            location: nil,
            date: Date(),
            source: "deposit"
        )

        let spendingLedger = LedgerEntryCache(
            recordName: "ledger_spending",
            profileRecordName: test.profileName,
            familyRecordName: test.familyName,
            amount: -3.0,
            entryDescription: "Health Potion",
            location: "Magic Shop",
            date: Date(),
            source: "manual"
        )

        viewModel.recomputeCharacterFromCache(
            profile: test.profile,
            completions: [questLog],
            ledgers: [questPayoutLedger, bonusLedger, spendingLedger],
            quests: [quest],
            profileAchievements: [],
            achievements: [],
            payoutDay: .sunday
        )

        // Wallet balance must equal ledger sum (10.0 + 5.0 - 3.0 = 12.0)
        // and NOT double-count questLog (which would inflate it to 22.0).
        #expect(viewModel.goldBalance == 12.0)
    }

    @Test
    func `recomputeCharacterFromCache filters ledgers by profile`() {
        let test = makeHarness()
        let viewModel = ProfileViewModel()

        let ownLedger = LedgerEntryCache(
            recordName: "l1",
            profileRecordName: test.profileName,
            familyRecordName: test.familyName,
            amount: 20.0,
            entryDescription: "Deposit",
            location: nil,
            date: Date(),
            source: "deposit"
        )

        let otherHeroLedger = LedgerEntryCache(
            recordName: "l2",
            profileRecordName: "other_hero",
            familyRecordName: test.familyName,
            amount: 50.0,
            entryDescription: "Other Deposit",
            location: nil,
            date: Date(),
            source: "deposit"
        )

        viewModel.recomputeCharacterFromCache(
            profile: test.profile,
            completions: [],
            ledgers: [ownLedger, otherHeroLedger],
            quests: [],
            profileAchievements: [],
            achievements: [],
            payoutDay: .sunday
        )

        #expect(viewModel.goldBalance == 20.0)
    }

    // MARK: - Avatar Emoji Selection

    private func makeProfile(emoji: String?) -> Profile {
        Profile(
            displayName: "Maya",
            role: .hero,
            iCloudUserID: SampleData.hero1UserID,
            family: SampleData.familyRef,
            avatarEmoji: emoji,
            id: SampleData.hero1ID
        )
    }

    @Test
    func `sample fixtures select a distinct emoji per family member`() {
        #expect(SampleData.heroProfile.avatarEmoji == "🦊")
        #expect(SampleData.secondHeroProfile.avatarEmoji == "🐯")
        #expect(SampleData.parentProfile.avatarEmoji == "🧔")
    }

    @Test
    func `emoji selection survives the domain-cache-domain round trip`() {
        let selected = makeProfile(emoji: "🐉")

        let cached = ProfileCache(from: selected)
        #expect(cached.avatarEmoji == "🐉")
        #expect(cached.toProfile(zoneID: SampleData.zoneID).avatarEmoji == "🐉")
    }

    @Test
    func `cache merge keeps the locally selected emoji over a stale server copy`() {
        let staleServer = makeProfile(emoji: "🧔")

        let merged = staleServer.mergingCacheValues(from: makeProfile(emoji: "🐉"))
        #expect(merged.avatarEmoji == "🐉")
    }

    @Test
    func `clearing the emoji propagates through the cache merge so deselection sticks`() {
        let staleServer = makeProfile(emoji: "🦊")

        let deselected = staleServer.mergingCacheValues(from: makeProfile(emoji: nil))
        #expect(deselected.avatarEmoji == nil)
    }

    // MARK: - TrophyRoomViewModel canonical key

    @Test
    func `trophyRoomViewModel latestEarnedTrophyName resolves via canonical key for both legacy and current record shapes`() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let appState = AppState()
        let familyID = CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        let family = Family(name: "Test Guild", createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID), id: familyID)
        let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let hero = Profile(
            displayName: "Test Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: heroID
        )
        appState.currentProfile = hero
        appState.family = family

        let achievementService = AchievementService(cloudKit: cloudKit, appState: appState)
        let xpService = XPService(cloudKit: cloudKit, appState: appState)
        let viewModel = TrophyRoomViewModel(
            achievementService: achievementService,
            xpService: xpService,
            appState: appState
        )

        let achievement = Achievement(
            id: CKRecord.ID(recordName: "fam1-\(AchievementRequirement.firstQuest.rawValue)", zoneID: zoneID),
            name: "First Steps",
            description: "Complete your first quest",
            iconSystemName: "shoeprints.fill",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: familyRef
        )
        let cache = AchievementCache(from: achievement)

        // Legacy shape stores bare requirement rawValue.
        let legacyPA = ProfileAchievementCache(
            recordName: "pa-legacy",
            achievementRecordName: AchievementRequirement.firstQuest.rawValue,
            profileRecordName: hero.id.recordName,
            familyRecordName: family.id.recordName,
            earnedDate: Date(timeIntervalSince1970: 1000)
        )
        viewModel.rebuildLists(earned: [legacyPA], allAchievements: [cache], profileCaches: [ProfileCache(from: hero)])
        #expect(viewModel.latestEarnedTrophyName == "First Steps")
        #expect(viewModel.earnedAchievementRecordNames.contains(AchievementRequirement.firstQuest.rawValue))

        // Current shape stores full deterministic recordName (family-prefixed).
        let currentPA = ProfileAchievementCache(
            recordName: "pa-current",
            achievementRecordName: "fam1-\(AchievementRequirement.firstQuest.rawValue)",
            profileRecordName: hero.id.recordName,
            familyRecordName: family.id.recordName,
            earnedDate: Date(timeIntervalSince1970: 2000)
        )
        viewModel.rebuildLists(earned: [currentPA], allAchievements: [cache], profileCaches: [ProfileCache(from: hero)])
        #expect(viewModel.latestEarnedTrophyName == "First Steps")

        // Both present — newest earnedDate wins, canonical lookup still resolves.
        viewModel.rebuildLists(earned: [legacyPA, currentPA], allAchievements: [cache], profileCaches: [ProfileCache(from: hero)])
        #expect(viewModel.latestEarnedTrophyName == "First Steps")
    }
}
