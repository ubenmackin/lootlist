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

    @Test
    func `isFullyCompleted returns false when targetCount is zero and approvedCount is zero`() async throws {
        let service = try makeService()
        let quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 5.0,
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

        let result = GoldCalculation.isFullyCompleted(quest: cached, approvedCount: 0)
        #expect(result == false)
    }

    @Test
    func `isFullyCompleted returns true when approvedCount meets target`() async throws {
        let service = try makeService()
        let quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 5.0,
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

        let result = GoldCalculation.isFullyCompleted(quest: cached, approvedCount: 3)
        #expect(result == true)
    }

    @Test
    func `isFullyCompleted returns false when approvedCount below target`() async throws {
        let service = try makeService()
        let quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 5.0,
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

        let result = GoldCalculation.isFullyCompleted(quest: cached, approvedCount: 2)
        #expect(result == false)
    }

    @Test
    func `isFullyCompleted returns true when approvedCount exceeds target`() async throws {
        let service = try makeService()
        let quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 5.0,
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

        let result = GoldCalculation.isFullyCompleted(quest: cached, approvedCount: 5)
        #expect(result == true)
    }

    @Test
    func `isFullyCompleted guards against zero targetCount with positive approved`() async throws {
        let service = try makeService()
        let quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 5.0,
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

        let result = GoldCalculation.isFullyCompleted(quest: cached, approvedCount: 1)
        #expect(result == true)
    }

    @Test
    func `quest overload guards against zero targetCount`() {
        let quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 5.0,
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

        #expect(GoldCalculation.isFullyCompleted(quest: quest, approvedCount: 0) == false)
        #expect(GoldCalculation.isFullyCompleted(quest: quest, approvedCount: 1) == true)
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
            goldReward: 9.0,
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
        #expect(GoldCalculation.isFullyCompleted(quest: quest, approvedCount: 1) == true)
        #expect(GoldCalculation.isFullyCompleted(quest: quest, approvedCount: 1, effectiveTarget: effective) == false)
        #expect(GoldCalculation.isFullyCompleted(quest: quest, approvedCount: 3, effectiveTarget: effective) == true)
        #expect(GoldCalculation.nonRejectedLogsReachTarget(quest: quest, nonRejectedCount: 1, effectiveTarget: effective) == false)
        #expect(GoldCalculation.nonRejectedLogsReachTarget(quest: quest, nonRejectedCount: 3, effectiveTarget: effective) == true)
        #expect(GoldCalculation.creditAsDouble(for: quest, approvedCount: 1) == 9.0)
        #expect(GoldCalculation.creditAsDouble(for: quest, approvedCount: 1, effectiveTarget: effective) == 3.0)
    }
}
