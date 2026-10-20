//
//  QuestRewardServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 10/18/26.
//

import CloudKit
import Foundation
@testable import LootList
import Synchronization
import Testing

@MainActor
struct QuestRewardServiceTests {
    private struct TestStack {
        let zoneID: CKRecordZone.ID
        let mock: MockCloudKitService
        let cloudKit: any CloudKitServiceProtocol
        let cache: CacheService
        let appState: AppState
        let hero: Profile
        let family: Family
    }

    // swiftformat:disable:next redundantParens
    private func makeStack(cloudKitOverride: (any CloudKitServiceProtocol)? = nil) throws -> TestStack {
        let zoneID = ExhaustiveCacheFixtures.sharedZoneID
        let mock = (cloudKitOverride as? MockCloudKitService) ?? MockCloudKitService()
        mock.activeFamilyZoneID = zoneID
        mock.activeIsOwner = true
        let cloudKit: any CloudKitServiceProtocol = cloudKitOverride ?? mock
        let defaults = UserDefaults.ephemeral()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let appState = AppState.testState(defaults: defaults)
        appState.cacheService = cache
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID)
        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID)
        appState.family = family
        appState.familyZoneID = zoneID
        appState.currentProfile = hero
        appState.isZoneOwner = true
        return TestStack(zoneID: zoneID, mock: mock, cloudKit: cloudKit, cache: cache, appState: appState, hero: hero, family: family)
    }

    private func makeRewardService(stack: TestStack) -> QuestRewardService {
        let xpService = XPService(cloudKit: stack.cloudKit, cacheService: stack.cache, appState: stack.appState)
        return QuestRewardService(
            cloudKit: stack.cloudKit,
            cacheService: stack.cache,
            appState: stack.appState,
            syncCoordinator: NoopSyncEnqueuing(),
            xpService: xpService
        )
    }

    private func makeQuest(
        familyRef: CKRecord.Reference,
        hero: Profile,
        name: String,
        recordName: String,
        zoneID: CKRecordZone.ID
    ) -> Quest {
        Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl-\(recordName)", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 10,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: WeekMath.mondayOfWeek(for: Date()),
            createdBy: CKRecord.Reference(recordID: hero.id, action: .none),
            family: familyRef,
            name: name,
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
    }

    private func makeCompletion(
        quest: Quest,
        hero: Profile,
        familyRef: CKRecord.Reference,
        recordName: String,
        zoneID: CKRecordZone.ID
    ) -> QuestCompletion {
        QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
            approvalMode: .autoApprove,
            completedDate: quest.weekOf,
            weekOf: quest.weekOf,
            family: familyRef,
            xpCredited: nil,
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
    }

    /// WHY bounded polling: interleaving checks are scheduling-sensitive, so a
    /// timed-out observation fails the test instead of hanging the suite.
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("Observation condition not met before timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Same-Hero Concurrency

    @Test
    func `two concurrent completions for the same hero credit XP additively`() async throws {
        let stack = try makeStack()
        let familyRef = ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: stack.zoneID)
        let questA = makeQuest(familyRef: familyRef, hero: stack.hero, name: "First Quest", recordName: "quest-a", zoneID: stack.zoneID)
        let questB = makeQuest(familyRef: familyRef, hero: stack.hero, name: "Second Quest", recordName: "quest-b", zoneID: stack.zoneID)
        let completionA = makeCompletion(quest: questA, hero: stack.hero, familyRef: familyRef, recordName: "completion-a", zoneID: stack.zoneID)
        let completionB = makeCompletion(quest: questB, hero: stack.hero, familyRef: familyRef, recordName: "completion-b", zoneID: stack.zoneID)

        await stack.cache.upsertFamily(stack.family)
        await stack.cache.upsertProfile(stack.hero)
        await stack.cache.upsertQuest(questA)
        await stack.cache.upsertQuest(questB)
        stack.mock.seedMockRecords([stack.family, stack.hero, questA, questB])
        stack.cache.markCacheFreshForTests(familyRecordName: stack.family.id.recordName, type: .questCompletion)

        let baselineXP = try #require(stack.cache.fetchProfile(recordName: stack.hero.id.recordName, family: stack.family.id.recordName)?.xpTotal)
        var heroValue = stack.hero
        heroValue.xp = baselineXP
        let hero = heroValue

        let rewardService = makeRewardService(stack: stack)

        async let firstGold: Int64 = try rewardService.applyReward(for: questA, to: hero, completion: completionA)
        async let secondGold: Int64 = try rewardService.applyReward(for: questB, to: hero, completion: completionB)
        _ = try await (firstGold, secondGold)

        let heroAfter = try #require(stack.cache.fetchProfile(
            recordName: stack.hero.id.recordName,
            family: stack.family.id.recordName
        ))
        // Single-completion award is exactly 50 (xpReward 50, no streak multiplier).
        #expect(heroAfter.xpTotal == baselineXP + 50 + 50, "Concurrent same-hero awards must arrive additively, never last-writer-wins")
        #expect(stack.cache.fetchRewardEvents(family: stack.family.id.recordName).count == 2, "Each distinct completion mints its own deterministic reward")
        #expect(cacheQuestBanked(stack: stack, quest: questA) == 50, "Each quest banks exactly its own bounty")
        #expect(cacheQuestBanked(stack: stack, quest: questB) == 50, "Each quest banks exactly its own bounty")
    }

    @Test
    func `two concurrent completions for the same quest bank XP additively`() async throws {
        let stack = try makeStack()
        let familyRef = ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: stack.zoneID)
        let quest = makeQuest(familyRef: familyRef, hero: stack.hero, name: "Shared Quest", recordName: "quest-shared", zoneID: stack.zoneID)
        let completionA = makeCompletion(quest: quest, hero: stack.hero, familyRef: familyRef, recordName: "completion-shared-a", zoneID: stack.zoneID)
        let completionB = makeCompletion(quest: quest, hero: stack.hero, familyRef: familyRef, recordName: "completion-shared-b", zoneID: stack.zoneID)

        await stack.cache.upsertFamily(stack.family)
        await stack.cache.upsertProfile(stack.hero)
        await stack.cache.upsertQuest(quest)
        stack.mock.seedMockRecords([stack.family, stack.hero, quest])
        stack.cache.markCacheFreshForTests(familyRecordName: stack.family.id.recordName, type: .questCompletion)

        let baselineXP = try #require(stack.cache.fetchProfile(recordName: stack.hero.id.recordName, family: stack.family.id.recordName)?.xpTotal)
        var heroValue = stack.hero
        heroValue.xp = baselineXP
        let hero = heroValue

        let rewardService = makeRewardService(stack: stack)

        async let firstGold: Int64 = try rewardService.applyReward(for: quest, to: hero, completion: completionA)
        async let secondGold: Int64 = try rewardService.applyReward(for: quest, to: hero, completion: completionB)
        _ = try await (firstGold, secondGold)

        let heroAfter = try #require(stack.cache.fetchProfile(
            recordName: stack.hero.id.recordName,
            family: stack.family.id.recordName
        ))
        #expect(heroAfter.xpTotal == baselineXP + 50 + 50, "Concurrent same-quest awards must arrive additively, never last-writer-wins")
        #expect(cacheQuestBanked(stack: stack, quest: quest) == 50 + 50, "Concurrent same-quest credits must both land in the bank row")
        #expect(stack.cache.fetchRewardEvents(family: stack.family.id.recordName).count == 2, "Each distinct completion mints its own deterministic reward")
    }

    @Test
    func `re-running applyReward for an already-credited completion mints nothing`() async throws {
        let stack = try makeStack()
        let familyRef = ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: stack.zoneID)
        let quest = makeQuest(familyRef: familyRef, hero: stack.hero, name: "Replay Quest", recordName: "quest-replay", zoneID: stack.zoneID)
        let completion = makeCompletion(quest: quest, hero: stack.hero, familyRef: familyRef, recordName: "completion-replay", zoneID: stack.zoneID)

        await stack.cache.upsertFamily(stack.family)
        await stack.cache.upsertProfile(stack.hero)
        await stack.cache.upsertQuest(quest)
        stack.mock.seedMockRecords([stack.family, stack.hero, quest])
        stack.cache.markCacheFreshForTests(familyRecordName: stack.family.id.recordName, type: .questCompletion)

        let baselineXP = try #require(stack.cache.fetchProfile(recordName: stack.hero.id.recordName, family: stack.family.id.recordName)?.xpTotal)
        var heroValue = stack.hero
        heroValue.xp = baselineXP
        let hero = heroValue

        let rewardService = makeRewardService(stack: stack)

        let firstRun = try await rewardService.applyReward(for: quest, to: hero, completion: completion)
        #expect(firstRun == 10)

        let heroAfterFirst = try #require(stack.cache.fetchProfile(recordName: stack.hero.id.recordName, family: stack.family.id.recordName))
        #expect(heroAfterFirst.xpTotal == baselineXP + 50)
        #expect(stack.cache.fetchRewardEvents(family: stack.family.id.recordName).count == 1)
        #expect(stack.cache.fetchRewardEvent(recordName: "reward-completion-replay", family: stack.family.id.recordName) != nil)

        // A stale caller replaying the same completion must repeat cached state, not mint XP.
        let replayRun = try await rewardService.applyReward(for: quest, to: hero, completion: completion)
        #expect(replayRun == 10)

        let heroAfterReplay = try #require(stack.cache.fetchProfile(recordName: stack.hero.id.recordName, family: stack.family.id.recordName))
        #expect(heroAfterReplay.xpTotal == baselineXP + 50, "Re-running an already-credited completion must not move XP")
        #expect(stack.cache.fetchRewardEvents(family: stack.family.id.recordName).count == 1, "Existing reward-{completionID} guarantee must hold on re-run")
        #expect(cacheQuestBanked(stack: stack, quest: quest) == 50)
    }

    private func cacheQuestBanked(stack: TestStack, quest: Quest) -> Int {
        stack.cache.fetchQuest(recordName: quest.id.recordName, family: stack.family.id.recordName)?.xpBanked ?? 0
    }

    // MARK: - Cross-Hero Independence

    private struct ClaimGateState {
        var armedCompletionRecordName: String?
        var released = false
        var parked: [CheckedContinuation<Void, Never>] = []
    }

    /// Parks one hero's deterministic claim inside the mock so the armed flow
    /// holds its keyed lock while another hero's flow must still drain freely.
    private final class RewardClaimGate: Sendable {
        private let lock = Mutex(ClaimGateState())

        func arm(parking completionRecordName: String) {
            lock.withLock { $0.armedCompletionRecordName = completionRecordName }
        }

        var parkedCount: Int {
            lock.withLock { $0.parked.count }
        }

        func parkWhenArmed(_ event: RewardEvent) async {
            let armed = lock.withLock { $0.armedCompletionRecordName }
            guard armed == event.questCompletion.recordID.recordName else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { state in
                    if state.released {
                        continuation.resume()
                    } else {
                        state.parked.append(continuation)
                    }
                }
            }
        }

        func release() {
            let toResume = lock.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.released = true
                let parked = state.parked
                state.parked.removeAll()
                return parked
            }
            for continuation in toResume {
                continuation.resume()
            }
        }
    }

    private final class GatedRewardClaimCloudKitService: MockCloudKitService {
        let claimGate = RewardClaimGate()

        override init(zoneID: CKRecordZone.ID? = nil) {
            super.init()
            self.activeFamilyZoneID = zoneID
        }

        override func claimRewardEvent(_ event: RewardEvent, in zoneID: CKRecordZone.ID? = nil, using db: CKDatabase? = nil) async throws -> Bool {
            await claimGate.parkWhenArmed(event)
            return try await super.claimRewardEvent(event, in: zoneID, using: db)
        }
    }

    @Test
    func `different heroes are not serialized against each other`() async throws {
        let gated = GatedRewardClaimCloudKitService()
        let stack = try makeStack(cloudKitOverride: gated)
        let gate = gated.claimGate

        let familyRef = ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: stack.zoneID)
        let parent = ExhaustiveCacheFixtures.sharedParent(zoneID: stack.zoneID)
        let heroB = ExhaustiveCacheFixtures.sharedHero(zoneID: stack.zoneID, displayName: "Second Hero", recordName: "hero2")
        stack.appState.currentProfile = parent

        let questA = makeQuest(familyRef: familyRef, hero: stack.hero, name: "Parked Quest", recordName: "quest-park-a", zoneID: stack.zoneID)
        let questB = makeQuest(familyRef: familyRef, hero: heroB, name: "Unblocked Quest", recordName: "quest-park-b", zoneID: stack.zoneID)
        let completionA = makeCompletion(quest: questA, hero: stack.hero, familyRef: familyRef, recordName: "completion-park-a", zoneID: stack.zoneID)
        let completionB = makeCompletion(quest: questB, hero: heroB, familyRef: familyRef, recordName: "completion-park-b", zoneID: stack.zoneID)

        await stack.cache.upsertFamily(stack.family)
        await stack.cache.upsertProfile(parent)
        await stack.cache.upsertProfile(stack.hero)
        await stack.cache.upsertProfile(heroB)
        await stack.cache.upsertQuest(questA)
        await stack.cache.upsertQuest(questB)
        stack.mock.seedMockRecords([stack.family, parent, stack.hero, heroB, questA, questB])
        stack.cache.markCacheFreshForTests(familyRecordName: stack.family.id.recordName, type: .questCompletion)

        let heroABaseline = try #require(stack.cache.fetchProfile(recordName: stack.hero.id.recordName, family: stack.family.id.recordName)?.xpTotal)
        let heroBBaseline = try #require(stack.cache.fetchProfile(recordName: heroB.id.recordName, family: stack.family.id.recordName)?.xpTotal)

        var heroAValue = stack.hero
        heroAValue.xp = heroABaseline
        let heroA = heroAValue
        var heroBValue = heroB
        heroBValue.xp = heroBBaseline
        let heroBAdjusted = heroBValue

        let rewardService = makeRewardService(stack: stack)
        gate.arm(parking: completionA.id.recordName)

        let parkedFlow = Task<Int64, Error>(priority: .userInitiated) {
            try await rewardService.applyReward(for: questA, to: heroA, completion: completionA)
        }

        // Deterministic parking: flow A now holds the hero-keyed lock inside its claim.
        try await waitUntil { gate.parkedCount > 0 }

        let freeFlow = Task<Int64, Error>(priority: .userInitiated) {
            try await rewardService.applyReward(for: questB, to: heroBAdjusted, completion: completionB)
        }

        // While flow A is parked, flow B must fully credit its hero — distinct keys do not wait.
        try await waitUntil {
            stack.cache.fetchProfile(recordName: heroB.id.recordName, family: stack.family.id.recordName)?.xpTotal == heroBBaseline + 50
        }
        let heroAWhileParked = try #require(stack.cache.fetchProfile(recordName: stack.hero.id.recordName, family: stack.family.id.recordName))
        #expect(heroAWhileParked.xpTotal == heroABaseline, "Parked hero must not have advanced past its claim")

        gate.release()
        let goldA = try await parkedFlow.value
        let goldB = try await freeFlow.value
        #expect(goldA == 10)
        #expect(goldB == 10)

        let heroAFinal = try #require(stack.cache.fetchProfile(recordName: stack.hero.id.recordName, family: stack.family.id.recordName))
        #expect(heroAFinal.xpTotal == heroABaseline + 50)
        let heroBFinal = try #require(stack.cache.fetchProfile(recordName: heroB.id.recordName, family: stack.family.id.recordName))
        #expect(heroBFinal.xpTotal == heroBBaseline + 50)
        #expect(stack.cache.fetchRewardEvents(family: stack.family.id.recordName).count == 2)
    }
}
