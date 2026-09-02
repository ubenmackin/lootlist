//
//  QuestServiceTests+Concurrency.swift
//  LootList
//
//  Created by Ben Mackin on 8/19/26.
//

import CloudKit
import Foundation
@testable import LootList
import Synchronization
import Testing

// MARK: - Concurrency Stress Harness: Mutex<Set> TOCTOU Guards

extension QuestServiceTests {
    @Test @MainActor
    func `concurrent markComplete on same quest serializes to one success`() async throws {
        let mockCK = MockCloudKitService(zoneID: CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner"))
        let scaffold = try MarkCompleteScaffold(approvalMode: .parentVerify, cloudKitOverride: mockCK)
        scaffold.cache.invalidateFreshness(familyRecordName: "fam1", type: .questCompletion)
        // Re-seed quest fresh after helper to ensure no stale pending log blocks the gate.
        await scaffold.cache.upsertQuest(scaffold.quest)

        let questService = scaffold.questService
        let quest = scaffold.quest
        let hero = scaffold.hero

        var tasks: [Task<Bool, Never>] = []
        for _ in 0 ..< 10 {
            tasks.append(Task { @MainActor in
                do {
                    _ = try await questService.markComplete(quest: quest, by: hero)
                    return true
                } catch let error as QuestServiceError where error == .alreadyInFlight {
                    return false
                } catch {
                    return false
                }
            })
        }

        var results: [Bool] = []
        for task in tasks {
            await results.append(task.value)
        }

        let successes = results.filter(\.self).count
        let rejected = results.filter { !$0 }.count
        #expect(successes == 1, "Exactly one concurrent markComplete must succeed")
        #expect(rejected == 9, "Nine concurrent markComplete attempts must throw alreadyInFlight")
        // Mutex entry must be cleared after settlement so a retry succeeds.
        #expect(questService.inFlightCompletions.withLock { $0.isEmpty })
    }

    @Test @MainActor
    func `concurrent verify on same log serializes to one success`() async throws {
        let mockCK = MockCloudKitService(zoneID: CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner"))
        let scaffold = try MarkCompleteScaffold(approvalMode: .parentVerify, cloudKitOverride: mockCK)
        let pending = scaffold.completion(status: .pending)
        await scaffold.cache.upsertQuestCompletion(pending)
        await scaffold.cache.upsertQuest(scaffold.quest)
        scaffold.cache.markCacheFreshForTests(familyRecordName: "fam1", type: .quest)
        scaffold.cache.markCacheFreshForTests(familyRecordName: "fam1", type: .questCompletion)
        scaffold.cache.markCacheFreshForTests(familyRecordName: "fam1", type: .profile)
        scaffold.appState.currentProfile = scaffold.parent

        let questService = scaffold.questService
        let parent = scaffold.parent

        var tasks: [Task<Bool, Never>] = []
        for _ in 0 ..< 10 {
            tasks.append(Task { @MainActor in
                do {
                    _ = try await questService.verify(questLog: pending, by: parent)
                    return true
                } catch let error as QuestServiceError where error == .alreadyInFlight {
                    return false
                } catch {
                    return false
                }
            })
        }

        var results: [Bool] = []
        for task in tasks {
            await results.append(task.value)
        }

        let successes = results.filter(\.self).count
        let rejected = results.filter { !$0 }.count
        #expect(successes == 1)
        #expect(rejected == 9)
        #expect(questService.inFlightVerifications.withLock { $0.isEmpty })
    }

    @Test @MainActor
    func `concurrent reject on same log serializes to one success`() async throws {
        let mockCK = MockCloudKitService(zoneID: CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner"))
        let scaffold = try MarkCompleteScaffold(approvalMode: .parentVerify, cloudKitOverride: mockCK)
        let pending = scaffold.completion(status: .pending, recordName: "log-reject")
        await scaffold.cache.upsertQuestCompletion(pending)
        await scaffold.cache.upsertQuest(scaffold.quest)
        scaffold.cache.markCacheFreshForTests(familyRecordName: "fam1", type: .quest)
        scaffold.cache.markCacheFreshForTests(familyRecordName: "fam1", type: .questCompletion)
        scaffold.cache.markCacheFreshForTests(familyRecordName: "fam1", type: .profile)
        scaffold.appState.currentProfile = scaffold.parent

        let questService = scaffold.questService
        let parent = scaffold.parent

        var tasks: [Task<Bool, Never>] = []
        for _ in 0 ..< 10 {
            tasks.append(Task { @MainActor in
                do {
                    _ = try await questService.reject(questLog: pending, by: parent)
                    return true
                } catch let error as QuestServiceError where error == .alreadyInFlight {
                    return false
                } catch {
                    return false
                }
            })
        }

        var results: [Bool] = []
        for task in tasks {
            await results.append(task.value)
        }

        let successes = results.filter(\.self).count
        let rejected = results.filter { !$0 }.count
        #expect(successes == 1)
        #expect(rejected == 9)
        #expect(questService.inFlightVerifications.withLock { $0.isEmpty })
    }

    @Test @MainActor
    func `concurrent withdraw on same log serializes to one success`() async throws {
        let mockCK = MockCloudKitService(zoneID: CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner"))
        let scaffold = try MarkCompleteScaffold(approvalMode: .parentVerify, cloudKitOverride: mockCK)
        let pending = scaffold.completion(status: .pending, recordName: "log-withdraw")
        await scaffold.cache.upsertQuestCompletion(pending)
        await scaffold.cache.upsertQuest(scaffold.quest)
        scaffold.cache.markCacheFreshForTests(familyRecordName: "fam1", type: .quest)
        scaffold.cache.markCacheFreshForTests(familyRecordName: "fam1", type: .questCompletion)
        scaffold.cache.markCacheFreshForTests(familyRecordName: "fam1", type: .profile)

        let questService = scaffold.questService
        let hero = scaffold.hero

        var tasks: [Task<Bool, Never>] = []
        for _ in 0 ..< 10 {
            tasks.append(Task { @MainActor in
                do {
                    try await questService.withdrawCompletion(questLog: pending, by: hero)
                    return true
                } catch let error as QuestServiceError where error == .alreadyInFlight {
                    return false
                } catch {
                    return false
                }
            })
        }

        var results: [Bool] = []
        for task in tasks {
            await results.append(task.value)
        }

        let successes = results.filter(\.self).count
        let rejected = results.filter { !$0 }.count
        #expect(successes == 1)
        #expect(rejected == 9)
        #expect(questService.inFlightWithdrawals.withLock { $0.isEmpty })
    }

    @Test
    func `mutex atomic insertIfAbsent prevents TOCTOU`() {
        let mutex = Mutex<Set<String>>([])
        let key = "quest1"
        let firstInserted = mutex.withLock { $0.insert(key).inserted }
        let secondInserted = mutex.withLock { $0.insert(key).inserted }
        #expect(firstInserted == true)
        #expect(secondInserted == false)
        #expect(mutex.withLock { $0.contains(key) })
        mutex.withLock { _ = $0.remove(key) }
        #expect(mutex.withLock { $0.isEmpty })
    }
}
