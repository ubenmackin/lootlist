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
    func `isFullyCompleted returns false when targetCount is zero and approvedCount is zero`() throws {
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
        service.upsertQuest(quest)

        guard let cached = service.fetchQuests(family: "fam").first else {
            Issue.record("Failed to fetch cached quest")
            return
        }

        let result = GoldCalculation.isFullyCompleted(quest: cached, approvedCount: 0)
        #expect(result == false)
    }

    @Test
    func `isFullyCompleted returns true when approvedCount meets target`() throws {
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
        service.upsertQuest(quest)

        guard let cached = service.fetchQuests(family: "fam").first else {
            Issue.record("Failed to fetch cached quest")
            return
        }

        let result = GoldCalculation.isFullyCompleted(quest: cached, approvedCount: 3)
        #expect(result == true)
    }

    @Test
    func `isFullyCompleted returns false when approvedCount below target`() throws {
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
        service.upsertQuest(quest)

        guard let cached = service.fetchQuests(family: "fam").first else {
            Issue.record("Failed to fetch cached quest")
            return
        }

        let result = GoldCalculation.isFullyCompleted(quest: cached, approvedCount: 2)
        #expect(result == false)
    }

    @Test
    func `isFullyCompleted returns true when approvedCount exceeds target`() throws {
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
        service.upsertQuest(quest)

        guard let cached = service.fetchQuests(family: "fam").first else {
            Issue.record("Failed to fetch cached quest")
            return
        }

        let result = GoldCalculation.isFullyCompleted(quest: cached, approvedCount: 5)
        #expect(result == true)
    }

    @Test
    func `isFullyCompleted guards against zero targetCount with positive approved`() throws {
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
        service.upsertQuest(quest)

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
}
