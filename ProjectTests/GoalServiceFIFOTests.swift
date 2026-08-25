//
//  GoalServiceFIFOTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct GoalServiceFIFOTests {
    // MARK: - Scaffold

    /// Helper: creates a goal with a specific age offset in hours so tests can
    /// control FIFO ordering predictably. These tests never touch CloudKit —
    /// they exercise `GoalService.allocate()` which is a pure function with no
    /// dependencies on caches or sync.
    private func makeGoal(recordName: String,
                          profileRecordName: String = "hero1",
                          bucketKind: BucketKind = .shortTermSave,
                          targetPennies: Int64,
                          hoursAgo: Int = 0,
                          completedAt: Date? = nil,
                          isArchived: Bool = false) -> GoalCache
    {
        let createdAt = Date().addingTimeInterval(TimeInterval(-hoursAgo * 3600))
        return GoalCache(
            recordName: recordName,
            profileRecordName: profileRecordName,
            familyRecordName: "fam1",
            bucketKind: bucketKind.rawValue,
            name: recordName,
            targetAmountPennies: targetPennies,
            createdAt: createdAt,
            completedAt: completedAt,
            isArchived: isArchived
        )
    }

    // MARK: - Allocation Tests

    @Test
    func `zero amount returns empty`() {
        let goals = [
            makeGoal(recordName: "g1", targetPennies: 1000, hoursAgo: 3),
            makeGoal(recordName: "g2", targetPennies: 500, hoursAgo: 2)
        ]
        let result = GoalService.allocate(amountPennies: 0, goals: goals)
        #expect(result.isEmpty)
    }

    @Test
    func `empty goals returns empty`() {
        let result = GoalService.allocate(amountPennies: 500, goals: [])
        #expect(result.isEmpty)
    }

    @Test
    func `negative amount treated as zero`() {
        let goals = [
            makeGoal(recordName: "g1", targetPennies: 1000)
        ]
        let result = GoalService.allocate(amountPennies: -100, goals: goals)
        #expect(result.isEmpty)
    }

    // MARK: - Single Goal

    @Test
    func `partial fill of single goal`() {
        let goals = [
            makeGoal(recordName: "g1", targetPennies: 1000, hoursAgo: 5)
        ]
        let result = GoalService.allocate(amountPennies: 400, goals: goals)
        #expect(result.count == 1)
        #expect(result[0].goalRecordName == "g1")
        #expect(result[0].allocatedPennies == 400)
    }

    @Test
    func `exact fill of single goal`() {
        let goals = [
            makeGoal(recordName: "g1", targetPennies: 1000, hoursAgo: 5)
        ]
        let result = GoalService.allocate(amountPennies: 1000, goals: goals)
        #expect(result.count == 1)
        #expect(result[0].allocatedPennies == 1000)
    }

    @Test
    func `overflow past single goal`() {
        let goals = [
            makeGoal(recordName: "g1", targetPennies: 1000, hoursAgo: 5)
        ]
        // Goal takes 1000, remaining 500 is surplus — not allocated.
        let result = GoalService.allocate(amountPennies: 1500, goals: goals)
        #expect(result.count == 1)
        #expect(result[0].allocatedPennies == 1000)
        // Total allocated is exactly the goal target.
        #expect(result.reduce(0) { $0 + $1.allocatedPennies } == 1000)
    }

    // MARK: - Multi-Goal Cascade

    @Test
    func `oldest goal fills first`() {
        let goals = [
            makeGoal(recordName: "g1", targetPennies: 500, hoursAgo: 10),
            makeGoal(recordName: "g2", targetPennies: 500, hoursAgo: 5)
        ]
        let result = GoalService.allocate(amountPennies: 600, goals: goals)
        #expect(result.count == 2)
        // Oldest (g1) fills first: 500.
        #expect(result[0].goalRecordName == "g1")
        #expect(result[0].allocatedPennies == 500)
        // Remaining 100 cascades to g2.
        #expect(result[1].goalRecordName == "g2")
        #expect(result[1].allocatedPennies == 100)
    }

    @Test
    func `overflow cascades across three goals`() {
        let goals = [
            makeGoal(recordName: "g1", targetPennies: 300, hoursAgo: 30),
            makeGoal(recordName: "g2", targetPennies: 300, hoursAgo: 20),
            makeGoal(recordName: "g3", targetPennies: 300, hoursAgo: 10)
        ]
        // 800 fills g1(300) + g2(300) + partial g3(200).
        let result = GoalService.allocate(amountPennies: 800, goals: goals)
        #expect(result.count == 3)
        #expect(result[0].goalRecordName == "g1")
        #expect(result[0].allocatedPennies == 300)
        #expect(result[1].goalRecordName == "g2")
        #expect(result[1].allocatedPennies == 300)
        #expect(result[2].goalRecordName == "g3")
        #expect(result[2].allocatedPennies == 200)
        #expect(result.reduce(0) { $0 + $1.allocatedPennies } == 800)
    }

    @Test
    func `last goal receives remainder exactly`() {
        let goals = [
            makeGoal(recordName: "g1", targetPennies: 250, hoursAgo: 5),
            makeGoal(recordName: "g2", targetPennies: 250, hoursAgo: 3)
        ]
        // 300 fills g1(250) + partial g2(50).
        let result = GoalService.allocate(amountPennies: 300, goals: goals)
        #expect(result.count == 2)
        #expect(result[0].allocatedPennies == 250)
        #expect(result[1].allocatedPennies == 50)
    }

    @Test
    func `all goals fully filled with exact total`() {
        let goals = [
            makeGoal(recordName: "g1", targetPennies: 100, hoursAgo: 10),
            makeGoal(recordName: "g2", targetPennies: 200, hoursAgo: 5),
            makeGoal(recordName: "g3", targetPennies: 300, hoursAgo: 1)
        ]
        let result = GoalService.allocate(amountPennies: 600, goals: goals)
        #expect(result.count == 3)
        #expect(result.reduce(0) { $0 + $1.allocatedPennies } == 600)
    }

    // MARK: - Archived Goals Skipped

    @Test
    func `archived goal is skipped entirely`() {
        let goals = [
            makeGoal(recordName: "active", targetPennies: 500, hoursAgo: 5),
            makeGoal(recordName: "archived", targetPennies: 500, hoursAgo: 10, isArchived: true)
        ]
        let result = GoalService.allocate(amountPennies: 500, goals: goals)
        #expect(result.count == 1)
        // The archived goal is oldest but skipped — active goal gets all 500.
        #expect(result[0].goalRecordName == "active")
        #expect(result[0].allocatedPennies == 500)
    }

    @Test
    func `cascade skips archived mid-stream`() {
        let goals = [
            makeGoal(recordName: "g1", targetPennies: 200, hoursAgo: 30),
            makeGoal(recordName: "g2-archived", targetPennies: 200, hoursAgo: 20, isArchived: true),
            makeGoal(recordName: "g3", targetPennies: 200, hoursAgo: 10)
        ]
        // g1 gets 200, g2 skipped, g3 gets 200.
        let result = GoalService.allocate(amountPennies: 500, goals: goals)
        #expect(result.count == 2)
        #expect(result[0].goalRecordName == "g1")
        #expect(result[1].goalRecordName == "g3")
        #expect(result[1].allocatedPennies == 200)
    }

    // MARK: - Completed Goals

    @Test
    func `completed goal consumes target but no allocation returned`() {
        let goals = [
            makeGoal(recordName: "done", targetPennies: 300, hoursAgo: 10,
                     completedAt: Date()),
            makeGoal(recordName: "active", targetPennies: 300, hoursAgo: 5)
        ]
        // 500: done consumes 300 (no allocation), 200 cascades to active.
        let result = GoalService.allocate(amountPennies: 500, goals: goals)
        #expect(result.count == 1)
        #expect(result[0].goalRecordName == "active")
        #expect(result[0].allocatedPennies == 200)
    }

    @Test
    func `completed goal consumes all funds leaving nothing for next`() {
        let goals = [
            makeGoal(recordName: "done", targetPennies: 600, hoursAgo: 10,
                     completedAt: Date()),
            makeGoal(recordName: "active", targetPennies: 300, hoursAgo: 5)
        ]
        // 500: done consumes 500 (still needs 100 more "in theory"), but pool
        // is exhausted so active gets nothing. Since done was already completed,
        // the 500 consumed from the pool evaporates — no allocation produced.
        let result = GoalService.allocate(amountPennies: 500, goals: goals)
        #expect(result.isEmpty)
    }

    // MARK: - All Archived = Surplus

    @Test
    func `all goals archived produces empty allocations`() {
        let goals = [
            makeGoal(recordName: "g1", targetPennies: 500, hoursAgo: 5, isArchived: true),
            makeGoal(recordName: "g2", targetPennies: 500, hoursAgo: 3, isArchived: true)
        ]
        let result = GoalService.allocate(amountPennies: 700, goals: goals)
        #expect(result.isEmpty)
    }

    @Test
    func `all goals completed produces empty allocations`() {
        let goals = [
            makeGoal(recordName: "g1", targetPennies: 500, hoursAgo: 5,
                     completedAt: Date()),
            makeGoal(recordName: "g2", targetPennies: 500, hoursAgo: 3,
                     completedAt: Date())
        ]
        let result = GoalService.allocate(amountPennies: 700, goals: goals)
        #expect(result.isEmpty)
    }

    // MARK: - Mixed Buckets

    @Test
    func `allocations carry profile and bucket fields`() {
        let goals = [
            makeGoal(recordName: "save1", profileRecordName: "hero1",
                     bucketKind: .shortTermSave, targetPennies: 500, hoursAgo: 5)
        ]
        let result = GoalService.allocate(amountPennies: 300, goals: goals)
        #expect(result.count == 1)
        #expect(result[0].profileRecordName == "hero1")
        #expect(result[0].bucketKind == BucketKind.shortTermSave.rawValue)
    }

    @Test
    func `goals from different buckets share pool but group independently`() {
        let goals = [
            makeGoal(recordName: "spend-1", profileRecordName: "hero1",
                     bucketKind: .spend, targetPennies: 500, hoursAgo: 10),
            makeGoal(recordName: "save-1", profileRecordName: "hero1",
                     bucketKind: .shortTermSave, targetPennies: 500, hoursAgo: 5)
        ]
        // Two buckets, single pool — spend gets filled first (oldest), remainder cascades.
        let result = GoalService.allocate(amountPennies: 700, goals: goals)
        #expect(result.count == 2)
        let spendAlloc = result.first { $0.bucketKind == BucketKind.spend.rawValue }
        let saveAlloc = result.first { $0.bucketKind == BucketKind.shortTermSave.rawValue }
        #expect(spendAlloc?.allocatedPennies == 500)
        #expect(saveAlloc?.allocatedPennies == 200)
    }

    // MARK: - Deterministic ID

    @Test
    func `contribution record name is deterministic`() {
        let name1 = GoalService.contributionRecordName(
            goalRecordName: "goal-abc", sourceEventID: "payout-001"
        )
        let name2 = GoalService.contributionRecordName(
            goalRecordName: "goal-abc", sourceEventID: "payout-001"
        )
        #expect(name1 == name2)
        #expect(name1 == "contrib-goal-abc-payout-001")
    }

    @Test
    func `contribution record names differ by source event`() {
        let id1 = GoalService.contributionRecordName(
            goalRecordName: "goal-abc", sourceEventID: "payout-001"
        )
        let id2 = GoalService.contributionRecordName(
            goalRecordName: "goal-abc", sourceEventID: "payout-002"
        )
        #expect(id1 != id2)
        #expect(id2 == "contrib-goal-abc-payout-002")
    }

    @Test
    func `contribution record names differ by goal`() {
        let id1 = GoalService.contributionRecordName(
            goalRecordName: "goal-abc", sourceEventID: "payout-001"
        )
        let id2 = GoalService.contributionRecordName(
            goalRecordName: "goal-xyz", sourceEventID: "payout-001"
        )
        #expect(id1 != id2)
        #expect(id2 == "contrib-goal-xyz-payout-001")
    }

    // MARK: - GoalAllocation Equatable

    @Test
    func `goal allocation is equatable`() {
        let al1 = GoalAllocation(
            goalRecordName: "g1", profileRecordName: "p1",
            bucketKind: "shortTermSave", allocatedPennies: 100
        )
        let al2 = GoalAllocation(
            goalRecordName: "g1", profileRecordName: "p1",
            bucketKind: "shortTermSave", allocatedPennies: 100
        )
        let al3 = GoalAllocation(
            goalRecordName: "g1", profileRecordName: "p1",
            bucketKind: "shortTermSave", allocatedPennies: 200
        )
        #expect(al1 == al2)
        #expect(al1 != al3)
    }
}
