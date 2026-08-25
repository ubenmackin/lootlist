//
//  HeroBoardServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/25/26.
//

import CloudKit
import Foundation
@testable import LootList
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

            let family = Family(name: "Test Guild", createdBy: parentID, id: familyRef.recordID)
            appState.family = family

            let questService = QuestService(cloudKit: cloudKit, xpService: XPService(cloudKit: cloudKit))
            questService.cacheService = cache
            questService.appState = appState
            boardService = HeroBoardService(questService: questService)

            appState.currentProfile = hero

            cache.upsertProfile(parent)
            cache.upsertProfile(hero)
            cache.upsertProfile(rivalHero)
            cache.upsertFamily(family)
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
                goldReward: 5.0,
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
    func `claim persists claimer and timestamp on cached board quest`() async throws {
        let ctx = try Scaffold()
        let quest = ctx.makeBoardQuest(name: "Dishes", recordName: "quest1")
        ctx.cache.upsertQuest(quest)

        let outcome = try await ctx.boardService.claim(quest, by: ctx.hero)

        #expect(outcome == .claimed)
        let cached = ctx.cachedQuest(recordName: "quest1")
        #expect(cached?.claimedByProfileRecordName == ctx.hero.id.recordName)
        #expect(cached?.claimedAt != nil)
    }

    @Test
    func `claim on already-claimed quest returns lost outcome without overwriting`() async throws {
        let ctx = try Scaffold()
        let originalClaimDate = Date(timeIntervalSince1970: 1_000_000)
        let quest = ctx.makeBoardQuest(
            name: "Dishes", recordName: "quest1",
            claimedBy: ctx.rivalHero.id.recordName, claimedAt: originalClaimDate
        )
        ctx.cache.upsertQuest(quest)

        let outcome = try await ctx.boardService.claim(quest, by: ctx.hero)

        #expect(outcome == .lostToAnotherHero)
        let cached = ctx.cachedQuest(recordName: "quest1")
        #expect(cached?.claimedByProfileRecordName == ctx.rivalHero.id.recordName)
        #expect(cached?.claimedAt == originalClaimDate)
    }

    @Test
    func `re-claim by the current claimer stays claimed`() async throws {
        let ctx = try Scaffold()
        let quest = ctx.makeBoardQuest(
            name: "Dishes", recordName: "quest1",
            claimedBy: ctx.hero.id.recordName, claimedAt: Date()
        )
        ctx.cache.upsertQuest(quest)

        let outcome = try await ctx.boardService.claim(quest, by: ctx.hero)

        #expect(outcome == .claimed)
        #expect(ctx.cachedQuest(recordName: "quest1")?.claimedByProfileRecordName == ctx.hero.id.recordName)
    }

    // MARK: - Revoke

    @Test
    func `parent revoke clears claim fields`() async throws {
        let ctx = try Scaffold()
        let quest = ctx.makeBoardQuest(
            name: "Dishes", recordName: "quest1",
            claimedBy: ctx.hero.id.recordName, claimedAt: Date()
        )
        ctx.cache.upsertQuest(quest)
        ctx.appState.currentProfile = ctx.parent

        try await ctx.boardService.revoke(quest)

        let cached = ctx.cachedQuest(recordName: "quest1")
        #expect(cached?.claimedByProfileRecordName == nil)
        #expect(cached?.claimedAt == nil)
        #expect(cached?.assigneeRecordName == HeroBoardService.boardAssigneeRecordName)
    }

    @Test
    func `revoke by a hero throws unauthorized`() async throws {
        let ctx = try Scaffold()
        let quest = ctx.makeBoardQuest(
            name: "Dishes", recordName: "quest1",
            claimedBy: ctx.rivalHero.id.recordName, claimedAt: Date()
        )
        ctx.cache.upsertQuest(quest)

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await ctx.boardService.revoke(quest)
        }
        #expect(ctx.cachedQuest(recordName: "quest1")?.claimedByProfileRecordName == ctx.rivalHero.id.recordName)
    }

    // MARK: - Board reads

    @Test
    func `board fetch filters assigned quests and partitions available vs claimed rows`() throws {
        let ctx = try Scaffold()
        let available = ctx.makeBoardQuest(name: "Alpha Chore", recordName: "q-a")
        let claimed = ctx.makeBoardQuest(
            name: "Beta Chore", recordName: "q-b",
            claimedBy: ctx.rivalHero.id.recordName, claimedAt: Date()
        )
        let assigned = ctx.makeBoardQuest(
            name: "Assigned Chore", recordName: "q-c",
            assigneeRecordName: ctx.hero.id.recordName
        )
        let inactive = ctx.makeBoardQuest(name: "Old Chore", recordName: "q-d", isActive: false)
        for quest in [available, claimed, assigned, inactive] {
            ctx.cache.upsertQuest(quest)
        }
        guard let family = ctx.appState.family else {
            Issue.record("Scaffold family missing")
            return
        }

        let boardNames = ctx.boardService.fetchBoardQuests(family: family).map(\.displayName)
        #expect(boardNames == ["Alpha Chore", "Beta Chore"])

        let availableNames = ctx.boardService.fetchAvailableBoardQuests(family: family).map(\.displayName)
        #expect(availableNames == ["Alpha Chore"])

        let claimedGroups = ctx.boardService.fetchClaimedBoardQuests(family: family)
        #expect(claimedGroups.count == 1)
        #expect(claimedGroups[ctx.rivalHero.id.recordName]?.map(\.displayName) == ["Beta Chore"])
    }
}
