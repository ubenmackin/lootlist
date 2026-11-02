//
//  GoldCalculationTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/7/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData
import Testing

@MainActor
struct GoldCalculationTests {
    private func makeService() throws -> CacheService {
        try CacheService(inMemory: true)
    }

    private func ref(_ name: String) -> CKRecord.Reference {
        CKRecord.Reference(recordID: CKRecord.ID(recordName: name), action: .none)
    }

    private func makeQuest(
        recordName: String,
        goldReward: Int64,
        targetCount: Int,
        isAllOrNothing: Bool = false
    ) -> Quest {
        Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: goldReward,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: targetCount,
            isAllOrNothing: isAllOrNothing,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("fam"),
            id: CKRecord.ID(recordName: recordName)
        )
    }

    private func makeLog(
        recordName: String,
        questRecordName: String,
        completedDate: Date,
        verificationStatus: VerificationStatus
    ) -> QuestCompletion {
        var log = QuestCompletion(
            quest: ref(questRecordName),
            completedBy: ref("hero"),
            approvalMode: .autoApprove,
            completedDate: completedDate,
            weekOf: completedDate,
            family: ref("fam"),
            id: CKRecord.ID(recordName: recordName)
        )
        log.verificationStatus = verificationStatus
        return log
    }

    @Test
    func `isFullyCompleted returns false when targetCount is zero and approvedCount is zero`() async throws {
        let service = try makeService()
        let quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 0,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("fam"),
            name: "Test Quest",
            id: CKRecord.ID(recordName: "quest1")
        )
        await service.upsertQuest(quest)

        guard let cached = service.fetchQuests(family: "fam").first else {
            Issue.record("Failed to fetch cached quest")
            return
        }

        let effective = SpecificDaysHelper.effectiveTarget(for: cached, specificDays: [])
        let result = GoldCalculation.isFullyCompleted(quest: cached, approvedCount: 0, effectiveTarget: effective)
        #expect(result == false)
    }

    @Test
    func `isFullyCompleted returns true when approvedCount meets target`() async throws {
        let service = try makeService()
        let quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 3,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("fam"),
            name: "Test Quest",
            id: CKRecord.ID(recordName: "quest1")
        )
        await service.upsertQuest(quest)

        guard let cached = service.fetchQuests(family: "fam").first else {
            Issue.record("Failed to fetch cached quest")
            return
        }

        let effective = SpecificDaysHelper.effectiveTarget(for: cached, specificDays: [])
        let result = GoldCalculation.isFullyCompleted(quest: cached, approvedCount: 3, effectiveTarget: effective)
        #expect(result == true)
    }

    @Test
    func `isFullyCompleted returns false when approvedCount below target`() async throws {
        let service = try makeService()
        let quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 3,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("fam"),
            name: "Test Quest",
            id: CKRecord.ID(recordName: "quest1")
        )
        await service.upsertQuest(quest)

        guard let cached = service.fetchQuests(family: "fam").first else {
            Issue.record("Failed to fetch cached quest")
            return
        }

        let effective = SpecificDaysHelper.effectiveTarget(for: cached, specificDays: [])
        let result = GoldCalculation.isFullyCompleted(quest: cached, approvedCount: 2, effectiveTarget: effective)
        #expect(result == false)
    }

    @Test
    func `isFullyCompleted returns true when approvedCount exceeds target`() async throws {
        let service = try makeService()
        let quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 2,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("fam"),
            name: "Test Quest",
            id: CKRecord.ID(recordName: "quest1")
        )
        await service.upsertQuest(quest)

        guard let cached = service.fetchQuests(family: "fam").first else {
            Issue.record("Failed to fetch cached quest")
            return
        }

        let effective = SpecificDaysHelper.effectiveTarget(for: cached, specificDays: [])
        let result = GoldCalculation.isFullyCompleted(quest: cached, approvedCount: 5, effectiveTarget: effective)
        #expect(result == true)
    }

    @Test
    func `isFullyCompleted guards against zero targetCount with positive approved`() async throws {
        let service = try makeService()
        let quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 0,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("fam"),
            name: "Test Quest",
            id: CKRecord.ID(recordName: "quest1")
        )
        await service.upsertQuest(quest)

        guard let cached = service.fetchQuests(family: "fam").first else {
            Issue.record("Failed to fetch cached quest")
            return
        }

        let effective = SpecificDaysHelper.effectiveTarget(for: cached, specificDays: [])
        let result = GoldCalculation.isFullyCompleted(quest: cached, approvedCount: 1, effectiveTarget: effective)
        #expect(result == true)
    }

    @Test
    func `quest overload guards against zero targetCount`() {
        let quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 0,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("fam"),
            name: "Test Quest",
            id: CKRecord.ID(recordName: "quest1")
        )

        let effective = SpecificDaysHelper.effectiveTarget(for: quest, specificDays: [])
        #expect(GoldCalculation.isFullyCompleted(quest: quest, approvedCount: 0, effectiveTarget: effective) == false)
        #expect(GoldCalculation.isFullyCompleted(quest: quest, approvedCount: 1, effectiveTarget: effective) == true)
    }

    @Test
    func `stale specificDays target requires day count not cached targetCount`() {
        let quest = QuestCache(
            recordName: "quest-stale",
            familyRecordName: "fam",
            assigneeRecordName: "hero",
            templateRecordName: "tpl",
            weekOf: Date(),
            questName: "Stale Quest",
            isActive: true,
            goldReward: 900,
            xpReward: 50,
            rarity: "common",
            scheduleType: QuestSchedule.specificDays.rawValue,
            isAllOrNothing: false,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            descriptionText: nil,
            createdByRecordName: "user1"
        )
        let days = ["monday", "wednesday", "friday"]
        // WHY: legacy rows keep targetCount 1 after template gains days, so slots must win.
        let effective = SpecificDaysHelper.effectiveTarget(for: quest, specificDays: days)
        #expect(effective == 3)
        #expect(GoldCalculation.isFullyCompleted(quest: quest, approvedCount: 1, effectiveTarget: effective) == false)
        #expect(GoldCalculation.isFullyCompleted(quest: quest, approvedCount: 3, effectiveTarget: effective) == true)
        #expect(GoldCalculation.nonRejectedLogsReachTarget(quest: quest, nonRejectedCount: 1, effectiveTarget: effective) == false)
        #expect(GoldCalculation.nonRejectedLogsReachTarget(quest: quest, nonRejectedCount: 3, effectiveTarget: effective) == true)
        #expect(GoldCalculation.creditPennies(for: quest, approvedCount: 1, effectiveTarget: effective) == 300)
        #expect(GoldCalculation.creditPennies(for: quest, approvedCount: 3, effectiveTarget: effective) == 900)
    }

    @Test
    func `realTimeAttributions emits prorated marginals that sum to totalCreditPennies`() {
        let quest = makeQuest(recordName: "quest1", goldReward: 2500, targetCount: 3)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let logs = [
            makeLog(recordName: "log-a", questRecordName: "quest1", completedDate: base, verificationStatus: .verified),
            makeLog(recordName: "log-b", questRecordName: "quest1", completedDate: base.addingTimeInterval(60), verificationStatus: .autoApproved),
            makeLog(recordName: "log-c", questRecordName: "quest1", completedDate: base.addingTimeInterval(120), verificationStatus: .verified)
        ]

        let attributions = GoldCalculation.realTimeAttributions(quests: [quest], logs: logs, templatesByID: [:])

        #expect(attributions.map(\.completionRecordName) == ["log-a", "log-b", "log-c"])
        // WHY exact slices: proration rounds each cumulative position half up: 833, 1667, 2500.
        #expect(attributions.map(\.pennies) == [833, 834, 833])
        #expect(attributions.map(\.pennies).reduce(0, +) == 2500)
        #expect(
            attributions.map(\.pennies).reduce(0, +)
                == GoldCalculation.totalCreditPennies(for: [quest], logs: logs, templatesByID: [:])
        )
    }

    @Test
    func `realTimeAttributions drops zero-marginal slices for all-or-nothing quests`() {
        let quest = makeQuest(recordName: "quest1", goldReward: 900, targetCount: 3, isAllOrNothing: true)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let logs = [
            makeLog(recordName: "log-a", questRecordName: "quest1", completedDate: base, verificationStatus: .autoApproved),
            makeLog(recordName: "log-b", questRecordName: "quest1", completedDate: base.addingTimeInterval(60), verificationStatus: .autoApproved),
            makeLog(recordName: "log-c", questRecordName: "quest1", completedDate: base.addingTimeInterval(120), verificationStatus: .autoApproved)
        ]

        let attributions = GoldCalculation.realTimeAttributions(quests: [quest], logs: logs, templatesByID: [:])

        // First two completions carry no marginal gold; the completing log carries the full reward.
        #expect(attributions.map(\.completionRecordName) == ["log-c"])
        #expect(attributions.map(\.pennies) == [900])
        #expect(
            attributions.map(\.pennies).reduce(0, +)
                == GoldCalculation.totalCreditPennies(for: [quest], logs: logs, templatesByID: [:])
        )
    }

    @Test
    func `realTimeAttributions stabilizes same-instant logs by record name regardless of insert order`() {
        let quest = makeQuest(recordName: "quest1", goldReward: 500, targetCount: 2)
        let sameInstant = Date(timeIntervalSince1970: 1_700_000_000)
        let logs = [
            makeLog(recordName: "log-z", questRecordName: "quest1", completedDate: sameInstant, verificationStatus: .verified),
            makeLog(recordName: "log-b", questRecordName: "quest1", completedDate: sameInstant, verificationStatus: .verified)
        ]

        let forward = GoldCalculation.realTimeAttributions(quests: [quest], logs: logs, templatesByID: [:])
        let reversed = GoldCalculation.realTimeAttributions(quests: [quest], logs: logs.reversed(), templatesByID: [:])

        #expect(forward.map(\.completionRecordName) == reversed.map(\.completionRecordName))
        #expect(forward.map(\.completionRecordName) == ["log-b", "log-z"])
        #expect(forward.map(\.pennies) == [250, 250])
    }

    @Test
    func `realTimeAttributions returns empty for rejected-only logs`() {
        let quest = makeQuest(recordName: "quest1", goldReward: 500, targetCount: 2)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let logs = [
            makeLog(recordName: "log-a", questRecordName: "quest1", completedDate: base, verificationStatus: .rejected),
            makeLog(recordName: "log-b", questRecordName: "quest1", completedDate: base.addingTimeInterval(60), verificationStatus: .rejected)
        ]

        #expect(GoldCalculation.realTimeAttributions(quests: [quest], logs: logs, templatesByID: [:]).isEmpty)
    }

    @Test
    func `realTimeAttributions emits nothing extra for over-target completions`() {
        let quest = makeQuest(recordName: "quest1", goldReward: 500, targetCount: 2)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let logs = [
            makeLog(recordName: "log-a", questRecordName: "quest1", completedDate: base, verificationStatus: .verified),
            makeLog(recordName: "log-b", questRecordName: "quest1", completedDate: base.addingTimeInterval(60), verificationStatus: .verified),
            makeLog(recordName: "log-c", questRecordName: "quest1", completedDate: base.addingTimeInterval(120), verificationStatus: .verified)
        ]

        let attributions = GoldCalculation.realTimeAttributions(quests: [quest], logs: logs, templatesByID: [:])

        #expect(attributions.map(\.completionRecordName) == ["log-a", "log-b"])
        #expect(attributions.map(\.pennies) == [250, 250])
        #expect(
            attributions.map(\.pennies).reduce(0, +)
                == GoldCalculation.totalCreditPennies(for: [quest], logs: logs, templatesByID: [:])
        )
    }
}
