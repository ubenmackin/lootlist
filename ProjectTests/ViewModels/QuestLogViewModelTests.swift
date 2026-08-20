//
//  QuestLogViewModelTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/19/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct QuestLogViewModelTests {
    private func makeViewModel() -> QuestLogViewModel {
        let familyZoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: familyZoneID)
        let appState = AppState()
        let familyID = CKRecord.ID(recordName: "fam1", zoneID: familyZoneID)
        let family = Family(name: "Test Family", createdBy: CKRecord.ID(recordName: "p1", zoneID: familyZoneID), id: familyID)
        appState.family = family
        appState.familyZoneID = familyZoneID
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        let familyService = FamilyService(cloudKit: cloudKit, appState: appState, questService: questService)
        return QuestLogViewModel(questService: questService, familyService: familyService, appState: appState)
    }

    @Test
    func `quest with approved progress and rejected attempt displays inProgress`() {
        let viewModel = makeViewModel()

        let hero = ProfileCache(
            recordName: "hero1",
            familyRecordName: "fam1",
            displayName: "Hero",
            role: "hero",
            xpTotal: 0,
            avatarName: nil,
            customAvatarImageData: nil,
            isActive: true,
            level: 1,
            iCloudUserRecordName: "u1",
            avatarClass: "knight",
            payoutPolicy: "perQuest"
        )

        let quest = QuestCache(
            recordName: "quest1",
            familyRecordName: "fam1",
            assigneeRecordName: "hero1",
            templateRecordName: "tmpl1",
            weekOf: WeekMath.startOfWeek(for: Date(), payoutDay: .sunday),
            questName: "Multi Step Quest",
            isActive: true,
            goldReward: 30.0,
            xpReward: 30,
            rarity: "common",
            scheduleType: "daily",
            targetCount: 3,
            isAllOrNothing: false,
            approvalMode: "parentVerify",
            descriptionText: nil,
            createdByRecordName: "p1"
        )

        let approvedLog = QuestCompletionCache(
            recordName: "log1",
            questRecordName: "quest1",
            familyRecordName: "fam1",
            completerRecordName: "hero1",
            completedDate: Date(),
            weekOf: quest.weekOf,
            verificationStatus: VerificationStatus.verified.rawValue,
            approvalMode: ApprovalMode.parentVerify.rawValue,
            verifiedByRecordName: "p1",
            verifiedDate: Date()
        )

        let rejectedLog = QuestCompletionCache(
            recordName: "log2",
            questRecordName: "quest1",
            familyRecordName: "fam1",
            completerRecordName: "hero1",
            completedDate: Date(),
            weekOf: quest.weekOf,
            verificationStatus: VerificationStatus.rejected.rawValue,
            approvalMode: ApprovalMode.parentVerify.rawValue,
            verifiedByRecordName: "p1",
            verifiedDate: Date()
        )

        viewModel.rebuildLists(
            profiles: [hero],
            quests: [quest],
            logs: [approvedLog, rejectedLog]
        )

        #expect(viewModel.displayedQuests.count == 1)
        let row = viewModel.displayedQuests[0]
        #expect(row.completionStatus == QuestLogViewModel.CompletionStatus.inProgress(completedCount: 1, targetCount: 3))
    }

    @Test
    func `quest with only rejected log displays rejected`() {
        let viewModel = makeViewModel()

        let hero = ProfileCache(
            recordName: "hero1",
            familyRecordName: "fam1",
            displayName: "Hero",
            role: "hero",
            xpTotal: 0,
            avatarName: nil,
            customAvatarImageData: nil,
            isActive: true,
            level: 1,
            iCloudUserRecordName: "u1",
            avatarClass: "knight",
            payoutPolicy: "perQuest"
        )

        let quest = QuestCache(
            recordName: "quest1",
            familyRecordName: "fam1",
            assigneeRecordName: "hero1",
            templateRecordName: "tmpl1",
            weekOf: WeekMath.startOfWeek(for: Date(), payoutDay: .sunday),
            questName: "Multi Step Quest",
            isActive: true,
            goldReward: 30.0,
            xpReward: 30,
            rarity: "common",
            scheduleType: "daily",
            targetCount: 3,
            isAllOrNothing: false,
            approvalMode: "parentVerify",
            descriptionText: nil,
            createdByRecordName: "p1"
        )

        let rejectedLog = QuestCompletionCache(
            recordName: "log2",
            questRecordName: "quest1",
            familyRecordName: "fam1",
            completerRecordName: "hero1",
            completedDate: Date(),
            weekOf: quest.weekOf,
            verificationStatus: VerificationStatus.rejected.rawValue,
            approvalMode: ApprovalMode.parentVerify.rawValue,
            verifiedByRecordName: "p1",
            verifiedDate: Date()
        )

        viewModel.rebuildLists(
            profiles: [hero],
            quests: [quest],
            logs: [rejectedLog]
        )

        #expect(viewModel.displayedQuests.count == 1)
        let row = viewModel.displayedQuests[0]
        #expect(row.completionStatus == QuestLogViewModel.CompletionStatus.rejected)
    }
}
