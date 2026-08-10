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
            zoneID: test.zoneID
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
            zoneID: test.zoneID
        )

        #expect(viewModel.goldBalance == 20.0)
    }
}
