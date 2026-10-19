//
//  HeroBoardServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/25/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData
import Testing

@MainActor
struct HeroBoardServiceTests {
    @MainActor
    struct Scaffold {
        let zoneID: CKRecordZone.ID
        let cloudKit: MockCloudKitService
        let cache: CacheService
        let appState: AppState
        let boardService: HeroBoardService
        fileprivate let deleteSpy: BoardDeleteSpy
        let familyRef: CKRecord.Reference
        let parent: Profile
        let hero: Profile
        let rivalHero: Profile

        init() throws {
            zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
            cloudKit = MockCloudKitService(zoneID: zoneID)
            cache = try CacheService(inMemory: true)
            appState = AppState(defaults: .ephemeral())
            appState.familyZoneID = zoneID
            appState.isZoneOwner = cloudKit.activeIsOwner

            familyRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
            )
            let parentID = CKRecord.ID(recordName: "parent1", zoneID: zoneID)
            parent = Profile(
                displayName: "Parent GM",
                avatarClass: .knight,
                avatarPresetID: "knight_01",
                role: .guildMaster,
                iCloudUserID: parentID,
                family: familyRef,
                id: parentID
            )
            let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
            hero = Profile(
                displayName: "Hero",
                avatarClass: .mage,
                avatarPresetID: "mage_01",
                role: .hero,
                iCloudUserID: heroID,
                family: familyRef,
                id: heroID
            )
            let rivalID = CKRecord.ID(recordName: "hero2", zoneID: zoneID)
            rivalHero = Profile(
                displayName: "Rival",
                avatarClass: .rogue,
                avatarPresetID: "rogue_01",
                role: .hero,
                iCloudUserID: rivalID,
                family: familyRef,
                id: rivalID
            )

            let family = Family(name: "Test Guild", creatorUserRecordName: parentID.recordName, id: familyRef.recordID)
            appState.family = family

            let questService = QuestService(cloudKit: cloudKit, xpService: XPService(cloudKit: cloudKit))
            questService.cacheService = cache
            questService.appState = appState
            deleteSpy = BoardDeleteSpy()
            boardService = HeroBoardService(
                questService: questService,
                cacheService: cache,
                syncCoordinator: deleteSpy,
                appState: appState
            )

            appState.currentProfile = hero

            cache.context?.insert(ProfileCache(from: parent))
            cache.context?.insert(ProfileCache(from: hero))
            cache.context?.insert(ProfileCache(from: rivalHero))
            cache.context?.insert(FamilyCache(from: family))
            _ = cache.saveContext()
            cloudKit.seedMockRecords([parent, hero, rivalHero])
        }

        func makeBoardQuest(name: String,
                            recordName: String,
                            assigneeRecordName: String = HeroBoardService.boardAssigneeRecordName,
                            claimedBy: String? = nil,
                            claimedAt: Date? = nil,
                            isActive: Bool = true) -> Quest
        {
            var quest = Quest(
                template: CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: "tmpl-\(recordName)", zoneID: zoneID), action: .none
                ),
                assignee: CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: assigneeRecordName, zoneID: zoneID), action: .none
                ),
                goldReward: 500,
                xpReward: 50,
                scheduleType: .weeklyFlexible,
                targetCount: 1,
                isAllOrNothing: false,
                approvalMode: .autoApprove,
                weekOf: WeekMath.startOfWeek(for: Date(), payoutDay: .sunday),
                createdBy: CKRecord.Reference(recordID: parent.id, action: .none),
                family: familyRef,
                name: name,
                id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
            )
            quest.active = isActive
            quest.claimedByProfileRecordName = claimedBy
            quest.claimedAt = claimedAt
            return quest
        }

        func cachedQuest(recordName: String) -> QuestCache? {
            cache.fetchQuest(recordName: recordName, family: "fam1")
        }
    }

    // MARK: - Claims

    @Test
    func `claim reassigns the quest to the claiming hero and stamps claim fields`() async throws {
        let ctx = try Scaffold()
        let quest = ctx.makeBoardQuest(name: "Dishes", recordName: "quest1")
        await ctx.cache.upsertQuest(quest)

        let outcome = try await ctx.boardService.claim(quest, by: ctx.hero)

        #expect(outcome == .claimed)
        let cached = try #require(ctx.cachedQuest(recordName: "quest1"))
        #expect(cached.claimedByProfileRecordName == ctx.hero.id.recordName)
        #expect(cached.claimedAt != nil)
        #expect(cached.assigneeRecordName == ctx.hero.id.recordName)
        // The reassigned quest leaves the board so the claiming hero's
        // checklist (assignee-derived) picks it up instead.
        #expect(!HeroBoardService.isBoardQuest(cached))
    }

    @Test
    func `checklist predicate lists a claimed quest for the claiming hero`() async throws {
        let ctx = try Scaffold()
        let quest = ctx.makeBoardQuest(name: "Dishes", recordName: "quest1")
        await ctx.cache.upsertQuest(quest)

        _ = try await ctx.boardService.claim(quest, by: ctx.hero)

        // The hero-only checklist reads via `QuestCache.assignedPredicate`, so
        // reassignment must land the quest under the claimer's record name.
        let checklistDescriptor = FetchDescriptor<QuestCache>(
            predicate: QuestCache.assignedPredicate(
                familyRecordName: "fam1",
                assigneeRecordName: ctx.hero.id.recordName
            )
        )
        let checklist = try #require(try ctx.cache.context?.fetch(checklistDescriptor))
        #expect(checklist.map(\.recordName) == ["quest1"])
    }

    @Test
    func `claim on already-claimed quest returns lost outcome without overwriting`() async throws {
        let ctx = try Scaffold()
        let originalClaimDate = Date(timeIntervalSince1970: 1_000_000)
        let quest = ctx.makeBoardQuest(
            name: "Dishes", recordName: "quest1",
            claimedBy: ctx.rivalHero.id.recordName, claimedAt: originalClaimDate
        )
        await ctx.cache.upsertQuest(quest)

        let outcome = try await ctx.boardService.claim(quest, by: ctx.hero)

        #expect(outcome == .lostToAnotherHero)
        let cached = ctx.cachedQuest(recordName: "quest1")
        #expect(cached?.claimedByProfileRecordName == ctx.rivalHero.id.recordName)
        #expect(cached?.claimedAt == originalClaimDate)
        // A lost race must not reassign the assignee — server-wins ingest reveals the winner.
        #expect(cached?.assigneeRecordName == HeroBoardService.boardAssigneeRecordName)
    }

    @Test
    func `re-claim by the current claimer stays claimed`() async throws {
        let ctx = try Scaffold()
        let quest = ctx.makeBoardQuest(
            name: "Dishes", recordName: "quest1",
            claimedBy: ctx.hero.id.recordName, claimedAt: Date()
        )
        await ctx.cache.upsertQuest(quest)

        let outcome = try await ctx.boardService.claim(quest, by: ctx.hero)

        #expect(outcome == .claimed)
        #expect(ctx.cachedQuest(recordName: "quest1")?.claimedByProfileRecordName == ctx.hero.id.recordName)
    }

    @Test
    func `concurrent losing claim does not clear the winners in-flight entry`() async throws {
        let ctx = try Scaffold()
        let quest = ctx.makeBoardQuest(name: "Dishes", recordName: "quest-race")
        await ctx.cache.upsertQuest(quest)

        // Three same-device taps racing one quest: only the winner runs the
        // claim path, so exactly one save enqueues and every tap reports claimed.
        async let first = ctx.boardService.claim(quest, by: ctx.hero)
        async let second = ctx.boardService.claim(quest, by: ctx.hero)
        async let third = ctx.boardService.claim(quest, by: ctx.hero)
        let outcomes = try await (first, second, third)

        #expect([outcomes.0, outcomes.1, outcomes.2].allSatisfy { $0 == .claimed })
        #expect(ctx.deleteSpy.savedRecordNames.filter { $0 == "quest-race" }.count == 1)
        #expect(ctx.cachedQuest(recordName: "quest-race")?.claimedByProfileRecordName == ctx.hero.id.recordName)
    }

    // MARK: - Revoke

    @Test
    func `parent revoke clears claim fields and restores the board assignee`() async throws {
        let ctx = try Scaffold()
        let quest = ctx.makeBoardQuest(
            name: "Dishes", recordName: "quest1",
            assigneeRecordName: ctx.hero.id.recordName,
            claimedBy: ctx.hero.id.recordName, claimedAt: Date()
        )
        await ctx.cache.upsertQuest(quest)
        ctx.appState.currentProfile = ctx.parent

        try await ctx.boardService.revoke(quest)

        let cached = try #require(ctx.cachedQuest(recordName: "quest1"))
        #expect(cached.claimedByProfileRecordName == nil)
        #expect(cached.claimedAt == nil)
        #expect(cached.assigneeRecordName == HeroBoardService.boardAssigneeRecordName)
        // Restoring the placeholder put the quest back on the board surface.
        #expect(HeroBoardService.isBoardQuest(cached))
    }

    @Test
    func `revoke by a hero throws unauthorized`() async throws {
        let ctx = try Scaffold()
        let quest = ctx.makeBoardQuest(
            name: "Dishes", recordName: "quest1",
            claimedBy: ctx.rivalHero.id.recordName, claimedAt: Date()
        )
        await ctx.cache.upsertQuest(quest)

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await ctx.boardService.revoke(quest)
        }
        #expect(ctx.cachedQuest(recordName: "quest1")?.claimedByProfileRecordName == ctx.rivalHero.id.recordName)
    }

    @Test
    func `revoke on a directly assigned quest without a claim stamp is a safe no-op`() async throws {
        let ctx = try Scaffold()
        let quest = ctx.makeBoardQuest(name: "Dishes", recordName: "quest1", assigneeRecordName: ctx.hero.id.recordName)
        await ctx.cache.upsertQuest(quest)
        ctx.appState.currentProfile = ctx.parent

        try await ctx.boardService.revoke(quest)

        // No claim stamp means no claim to release — the direct assignment and
        // the hero's checklist entry must survive untouched.
        let cached = try #require(ctx.cachedQuest(recordName: "quest1"))
        #expect(cached.claimedByProfileRecordName == nil)
        #expect(cached.claimedAt == nil)
        #expect(cached.assigneeRecordName == ctx.hero.id.recordName)
        #expect(!HeroBoardService.isBoardQuest(cached))
    }

    @Test
    func `revoke on an unclaimed board quest is a no-op`() async throws {
        let ctx = try Scaffold()
        let quest = ctx.makeBoardQuest(name: "Dishes", recordName: "quest1")
        await ctx.cache.upsertQuest(quest)
        ctx.appState.currentProfile = ctx.parent

        try await ctx.boardService.revoke(quest)

        let cached = try #require(ctx.cachedQuest(recordName: "quest1"))
        #expect(cached.claimedByProfileRecordName == nil)
        #expect(cached.claimedAt == nil)
        #expect(cached.assigneeRecordName == HeroBoardService.boardAssigneeRecordName)
        #expect(HeroBoardService.isBoardQuest(cached))
    }

    // MARK: - Remove from board

    @Test
    func `parent remove deletes quest and ad-hoc template rows and enqueues two deletes`() async throws {
        let ctx = try Scaffold()
        let quest = ctx.makeBoardQuest(name: "Plants", recordName: "quest1")
        // postToBoard always mints one inactive ad-hoc template per quest.
        let adhocTemplate = QuestTemplate(
            name: "Plants",
            description: "",
            defaultGold: 500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            createdBy: CKRecord.Reference(recordID: ctx.parent.id, action: .none),
            family: ctx.familyRef,
            isActive: false,
            id: CKRecord.ID(recordName: "tmpl-quest1", zoneID: ctx.zoneID)
        )
        await ctx.cache.upsertQuest(quest)
        await ctx.cache.upsertQuestTemplate(adhocTemplate)
        ctx.appState.currentProfile = ctx.parent

        try await ctx.boardService.removeFromBoard(quest)

        #expect(ctx.cachedQuest(recordName: "quest1") == nil)
        #expect(ctx.cache.fetchQuestTemplate(recordName: "tmpl-quest1", family: "fam1") == nil)
        #expect(ctx.deleteSpy.deletedRecordNames == ["quest1", "tmpl-quest1"])
    }

    @Test
    func `remove by a hero throws unauthorized`() async throws {
        let ctx = try Scaffold()
        let quest = ctx.makeBoardQuest(name: "Dishes", recordName: "quest1")
        await ctx.cache.upsertQuest(quest)

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await ctx.boardService.removeFromBoard(quest)
        }
        #expect(ctx.deleteSpy.deletedRecordNames.isEmpty)
        #expect(ctx.cachedQuest(recordName: "quest1") != nil)
    }

    @Test
    func `remove of a claimed quest throws and deletes nothing`() async throws {
        let ctx = try Scaffold()
        let quest = ctx.makeBoardQuest(
            name: "Dishes", recordName: "quest1",
            assigneeRecordName: ctx.hero.id.recordName,
            claimedBy: ctx.hero.id.recordName, claimedAt: Date()
        )
        await ctx.cache.upsertQuest(quest)
        ctx.appState.currentProfile = ctx.parent

        await #expect(throws: QuestServiceError.staleData("Revoke the claim before removing this quest from the board")) {
            try await ctx.boardService.removeFromBoard(quest)
        }
        #expect(ctx.deleteSpy.deletedRecordNames.isEmpty)
        #expect(ctx.cachedQuest(recordName: "quest1") != nil)
    }

    @Test
    func `remove of a directly assigned quest throws and deletes nothing`() async throws {
        let ctx = try Scaffold()
        let quest = ctx.makeBoardQuest(name: "Dishes", recordName: "quest1", assigneeRecordName: ctx.hero.id.recordName)
        await ctx.cache.upsertQuest(quest)
        ctx.appState.currentProfile = ctx.parent

        await #expect(throws: QuestServiceError.staleData("Only board quests can be removed from the board")) {
            try await ctx.boardService.removeFromBoard(quest)
        }
        #expect(ctx.deleteSpy.deletedRecordNames.isEmpty)
        #expect(ctx.cachedQuest(recordName: "quest1") != nil)
    }

    @Test
    func `remove without the ad-hoc template row throws and deletes nothing`() async throws {
        let ctx = try Scaffold()
        let quest = ctx.makeBoardQuest(name: "Dishes", recordName: "quest1")
        await ctx.cache.upsertQuest(quest)
        ctx.appState.currentProfile = ctx.parent

        await #expect(throws: QuestServiceError.staleData("Board quest template row is missing")) {
            try await ctx.boardService.removeFromBoard(quest)
        }
        #expect(ctx.deleteSpy.deletedRecordNames.isEmpty)
        #expect(ctx.cachedQuest(recordName: "quest1") != nil)
    }

    // MARK: - Board reads

    @Test
    func `board fetch filters assigned quests and partitions available vs claimed rows`() async throws {
        let ctx = try Scaffold()
        let available = ctx.makeBoardQuest(name: "Alpha Chore", recordName: "q-a")
        let claimed = ctx.makeBoardQuest(
            name: "Beta Chore", recordName: "q-b",
            assigneeRecordName: ctx.rivalHero.id.recordName,
            claimedBy: ctx.rivalHero.id.recordName, claimedAt: Date()
        )
        let assigned = ctx.makeBoardQuest(
            name: "Assigned Chore", recordName: "q-c",
            assigneeRecordName: ctx.hero.id.recordName
        )
        let inactive = ctx.makeBoardQuest(name: "Old Chore", recordName: "q-d", isActive: false)
        for quest in [available, claimed, assigned, inactive] {
            await ctx.cache.upsertQuest(quest)
        }
        guard let family = ctx.appState.family else {
            Issue.record("Scaffold family missing")
            return
        }

        // A claimed quest reassigned to its claimer is no longer on the board —
        // only truly unclaimed placeholder rows remain "On the Board".
        let boardNames = ctx.boardService.fetchBoardQuests(family: family).map(\.displayName)
        #expect(boardNames == ["Alpha Chore"])

        let availableNames = ctx.boardService.fetchAvailableBoardQuests(family: family).map(\.displayName)
        #expect(availableNames == ["Alpha Chore"])

        // Claimed grouping keys on the claim stamp, keyed by claimant.
        let claimedGroups = ctx.boardService.fetchClaimedBoardQuests(family: family)
        #expect(claimedGroups.count == 1)
        #expect(claimedGroups[ctx.rivalHero.id.recordName]?.map(\.displayName) == ["Beta Chore"])
    }

    // MARK: - Prompt count helper

    @Test
    func `prompt count helper counts only available board rows`() async throws {
        let ctx = try Scaffold()
        let available = ctx.makeBoardQuest(name: "Alpha Chore", recordName: "q-a")
        let claimed = ctx.makeBoardQuest(
            name: "Beta Chore", recordName: "q-b",
            assigneeRecordName: ctx.rivalHero.id.recordName,
            claimedBy: ctx.rivalHero.id.recordName, claimedAt: Date()
        )
        let assigned = ctx.makeBoardQuest(
            name: "Assigned Chore", recordName: "q-c",
            assigneeRecordName: ctx.hero.id.recordName
        )
        let inactive = ctx.makeBoardQuest(name: "Old Chore", recordName: "q-d", isActive: false)
        for quest in [available, claimed, assigned, inactive] {
            await ctx.cache.upsertQuest(quest)
        }

        let rows = ctx.cache.fetchQuests(family: "fam1")
        #expect(HeroBoardService.availableBoardQuestCount(from: rows) == 1)
    }

    @Test
    func `zero claimable rows leave the prompt card out of the child home hierarchy`() async throws {
        let ctx = try Scaffold()
        let claimed = ctx.makeBoardQuest(
            name: "Beta Chore", recordName: "q-b",
            assigneeRecordName: ctx.rivalHero.id.recordName,
            claimedBy: ctx.rivalHero.id.recordName, claimedAt: Date()
        )
        let assigned = ctx.makeBoardQuest(
            name: "Assigned Chore", recordName: "q-c",
            assigneeRecordName: ctx.hero.id.recordName
        )
        let inactive = ctx.makeBoardQuest(name: "Old Chore", recordName: "q-d", isActive: false)
        for quest in [claimed, assigned, inactive] {
            await ctx.cache.upsertQuest(quest)
        }

        // HeroHomeView renders the prompt card only when this count is
        // positive, so a zero result removes the card instead of leaving an
        // empty shell.
        #expect(HeroBoardService.availableBoardQuestCount(from: []) == 0)
        let rows = ctx.cache.fetchQuests(family: "fam1")
        #expect(HeroBoardService.availableBoardQuestCount(from: rows) == 0)
    }
}

/// WHY spy: records engine-bound saves and tombstones without a live CKSyncEngine.
@MainActor
private final class BoardDeleteSpy: SyncEnqueuing {
    var savedRecordNames: [String] = []
    var deletedRecordNames: [String] = []
    func enqueueSave(recordID: CKRecord.ID, isOwner _: Bool) {
        savedRecordNames.append(recordID.recordName)
    }

    func enqueueDelete(recordID: CKRecord.ID, isOwner _: Bool) {
        deletedRecordNames.append(recordID.recordName)
    }

    func batchEnqueueSave(recordIDs _: [CKRecord.ID], isOwner _: Bool) {}
}
