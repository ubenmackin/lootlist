//
//  HeroBoardViewModelTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/25/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct HeroBoardViewModelTests {
    @MainActor
    struct Scaffold {
        static let familyRecordName = "fam1"

        let zoneID: CKRecordZone.ID
        let cloudKit: MockCloudKitService
        let cache: CacheService
        let appState: AppState
        let toastManager: ToastManager
        let boardService: HeroBoardService
        let viewModel: HeroBoardViewModel
        let parent: Profile
        let hero: Profile

        init() throws {
            zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
            cloudKit = MockCloudKitService(zoneID: zoneID)
            cache = try CacheService(inMemory: true)
            appState = AppState(defaults: .ephemeral())
            appState.familyZoneID = zoneID
            appState.isZoneOwner = cloudKit.activeIsOwner

            let familyRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: Self.familyRecordName, zoneID: zoneID), action: .none
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

            let family = Family(name: "Test Guild", createdBy: parentID, id: familyRef.recordID)
            appState.family = family

            toastManager = ToastManager()
            let questService = QuestService(
                cloudKit: cloudKit,
                xpService: XPService(cloudKit: cloudKit),
                toastManager: toastManager
            )
            questService.cacheService = cache
            questService.appState = appState
            boardService = HeroBoardService(questService: questService)
            viewModel = HeroBoardViewModel(boardService: boardService, appState: appState)

            appState.currentProfile = hero

            cache.context?.insert(ProfileCache(from: parent))
            cache.context?.insert(ProfileCache(from: hero))
            cache.context?.insert(FamilyCache(from: family))
            _ = cache.saveContext()
        }

        func makeCacheRow(recordName: String,
                          name: String,
                          assigneeRecordName: String = HeroBoardService.boardAssigneeRecordName,
                          claimedBy: String? = nil,
                          claimedAt: Date? = nil,
                          isActive: Bool = true) -> QuestCache
        {
            QuestCache(
                recordName: recordName,
                familyRecordName: Self.familyRecordName,
                assigneeRecordName: assigneeRecordName,
                templateRecordName: "tmpl-\(recordName)",
                weekOf: WeekMath.startOfWeek(for: Date(), payoutDay: .sunday),
                questName: name,
                isActive: isActive,
                goldReward: 5.0,
                xpReward: 50,
                rarity: "common",
                scheduleType: QuestSchedule.weeklyFlexible.rawValue,
                isAllOrNothing: false,
                approvalMode: ApprovalMode.autoApprove.rawValue,
                descriptionText: nil,
                createdByRecordName: parent.id.recordName,
                claimedByProfileRecordName: claimedBy,
                claimedAt: claimedAt
            )
        }

        func profileCache(recordName: String, displayName: String, role: String) -> ProfileCache {
            ProfileCache(
                recordName: recordName,
                familyRecordName: Self.familyRecordName,
                displayName: displayName,
                role: role,
                xpTotal: 0,
                avatarName: nil,
                customAvatarImageData: nil,
                isActive: true,
                level: 1,
                iCloudUserRecordName: "u-\(recordName)",
                avatarClass: "mage",
                payoutPolicy: "perQuest"
            )
        }

        var heroProfileCache: ProfileCache {
            profileCache(recordName: hero.id.recordName, displayName: hero.displayName, role: UserRole.hero.rawValue)
        }

        var rivalProfileCache: ProfileCache {
            profileCache(recordName: "hero2", displayName: "Rival", role: UserRole.hero.rawValue)
        }

        func cachedQuest(recordName: String) -> QuestCache? {
            cache.fetchQuest(recordName: recordName, family: Self.familyRecordName)
        }
    }

    // MARK: - Filtering

    @Test
    func `rebuild partitions available vs claimed rows and drops assigned and inactive quests`() throws {
        let ctx = try Scaffold()
        let available = ctx.makeCacheRow(recordName: "q-a", name: "Alpha Chore")
        let claimed = ctx.makeCacheRow(recordName: "q-b", name: "Beta Chore", claimedBy: "hero2", claimedAt: Date())
        let assigned = ctx.makeCacheRow(recordName: "q-c", name: "Assigned Chore", assigneeRecordName: "hero1")
        let inactive = ctx.makeCacheRow(recordName: "q-d", name: "Old Chore", isActive: false)

        ctx.viewModel.rebuildLists(
            quests: [available, claimed, assigned, inactive],
            profiles: [ctx.heroProfileCache, ctx.rivalProfileCache]
        )

        #expect(ctx.viewModel.availableRows.map(\.id) == ["q-a"])
        #expect(ctx.viewModel.claimedRows.map(\.id) == ["q-b"])
        #expect(ctx.viewModel.claimedRows.first?.claimantName == "Rival")
        #expect(ctx.viewModel.claimedRows.first?.isClaimedByCurrentUser == false)
    }

    // MARK: - Claim flow

    @Test
    func `successful claim moves row to claimed by current user`() async throws {
        let ctx = try Scaffold()
        await ctx.cache.upsertQuest(ctx.makeCacheRow(recordName: "q-a", name: "Alpha Chore").toQuest(zoneID: ctx.zoneID))
        try ctx.viewModel.rebuildLists(quests: [#require(ctx.cachedQuest(recordName: "q-a"))], profiles: [ctx.heroProfileCache])

        let row = try #require(ctx.viewModel.availableRows.first)
        await ctx.viewModel.claim(row)

        #expect(!ctx.viewModel.isClaiming(row))
        #expect(ctx.cachedQuest(recordName: "q-a")?.claimedByProfileRecordName == ctx.hero.id.recordName)

        try ctx.viewModel.rebuildLists(quests: [#require(ctx.cachedQuest(recordName: "q-a"))], profiles: [ctx.heroProfileCache])
        #expect(ctx.viewModel.availableRows.isEmpty)
        #expect(ctx.viewModel.claimedRows.map(\.id) == ["q-a"])
        #expect(ctx.viewModel.claimedRows.first?.isClaimedByCurrentUser == true)
        // The settled pending claim belongs to the current user, so no conflict toast fires.
        #expect(ctx.toastManager.toasts.isEmpty)
    }

    @Test
    func `lost claim race surfaces conflict toast without overwriting the rival`() async throws {
        let ctx = try Scaffold()
        let rivalWinDate = Date(timeIntervalSince1970: 2_000_000)
        let rivalWin = ctx.makeCacheRow(
            recordName: "q-a", name: "Alpha Chore",
            claimedBy: "hero2", claimedAt: rivalWinDate
        )
        await ctx.cache.upsertQuest(rivalWin.toQuest(zoneID: ctx.zoneID))

        // The child's list still shows the stale unclaimed copy when they tap.
        let staleQuest = ctx.makeCacheRow(recordName: "q-a", name: "Alpha Chore").toQuest(zoneID: ctx.zoneID)
        let staleRow = HeroBoardViewModel.BoardRow(quest: staleQuest, claimantName: nil, isClaimedByCurrentUser: false)

        await ctx.viewModel.claim(staleRow)

        #expect(ctx.toastManager.toasts.contains { $0.message == "Someone grabbed it first!" && $0.type == .warning })
        #expect(ctx.cachedQuest(recordName: "q-a")?.claimedByProfileRecordName == "hero2")
        #expect(ctx.cachedQuest(recordName: "q-a")?.claimedAt == rivalWinDate)
    }

    @Test
    func `ingested rival claim after a local win surfaces conflict toast`() async throws {
        let ctx = try Scaffold()
        await ctx.cache.upsertQuest(ctx.makeCacheRow(recordName: "q-a", name: "Alpha Chore").toQuest(zoneID: ctx.zoneID))
        try ctx.viewModel.rebuildLists(quests: [#require(ctx.cachedQuest(recordName: "q-a"))], profiles: [ctx.heroProfileCache])

        let row = try #require(ctx.viewModel.availableRows.first)
        await ctx.viewModel.claim(row)

        // Server-wins ingest lands afterwards revealing the rival's claim.
        let rivalWin = ctx.makeCacheRow(recordName: "q-a", name: "Alpha Chore", claimedBy: "hero2", claimedAt: Date())
        await ctx.cache.upsertQuest(rivalWin.toQuest(zoneID: ctx.zoneID))

        ctx.viewModel.rebuildLists(quests: [rivalWin], profiles: [ctx.heroProfileCache, ctx.rivalProfileCache])

        #expect(ctx.toastManager.toasts.contains { $0.message == "Someone grabbed it first!" && $0.type == .warning })
    }

    // MARK: - Parent reset

    @Test
    func `parent reset returns claimed quest to the board`() async throws {
        let ctx = try Scaffold()
        let claimedAt = Date(timeIntervalSince1970: 3_000_000)
        await ctx.cache.upsertQuest(
            ctx.makeCacheRow(recordName: "q-a", name: "Alpha Chore", claimedBy: "hero1", claimedAt: claimedAt)
                .toQuest(zoneID: ctx.zoneID)
        )
        try ctx.viewModel.rebuildLists(quests: [#require(ctx.cachedQuest(recordName: "q-a"))], profiles: [ctx.heroProfileCache])

        let row = try #require(ctx.viewModel.claimedRows.first)
        ctx.appState.currentProfile = ctx.parent
        await ctx.viewModel.revoke(row)

        let cached = ctx.cachedQuest(recordName: "q-a")
        #expect(cached?.claimedByProfileRecordName == nil)
        #expect(cached?.claimedAt == nil)

        ctx.appState.currentProfile = ctx.hero
        try ctx.viewModel.rebuildLists(quests: [#require(cached)], profiles: [ctx.heroProfileCache])
        #expect(ctx.viewModel.availableRows.map(\.id) == ["q-a"])
        #expect(ctx.viewModel.claimedRows.isEmpty)
    }

    @Test
    func `reset attempted by a hero shows error toast and leaves claim intact`() async throws {
        let ctx = try Scaffold()
        let claimedAt = Date(timeIntervalSince1970: 4_000_000)
        await ctx.cache.upsertQuest(
            ctx.makeCacheRow(recordName: "q-a", name: "Alpha Chore", claimedBy: "hero2", claimedAt: claimedAt)
                .toQuest(zoneID: ctx.zoneID)
        )
        try ctx.viewModel.rebuildLists(quests: [#require(ctx.cachedQuest(recordName: "q-a"))], profiles: [ctx.rivalProfileCache])

        let row = try #require(ctx.viewModel.claimedRows.first)
        await ctx.viewModel.revoke(row)

        #expect(ctx.toastManager.toasts.contains { $0.type == .error })
        #expect(ctx.cachedQuest(recordName: "q-a")?.claimedByProfileRecordName == "hero2")
        #expect(ctx.cachedQuest(recordName: "q-a")?.claimedAt == claimedAt)
    }
}
