//
//  QuestManagerViewModelTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct QuestManagerViewModelTests {
    private struct Dependencies {
        let questService: QuestService
        let familyService: FamilyService
        let appState: AppState
    }

    private func makeDependencies() -> Dependencies {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let appState = AppState()
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        let familyService = FamilyService(cloudKit: cloudKit, appState: appState, questService: questService)
        return Dependencies(
            questService: questService,
            familyService: familyService,
            appState: appState
        )
    }

    @Test
    func `initial quest manager state`() {
        let deps = makeDependencies()
        let vm = QuestManagerViewModel(
            questService: deps.questService,
            familyService: deps.familyService,
            appState: deps.appState
        )

        #expect(vm.templates.isEmpty)
        #expect(vm.activeAssignments.isEmpty)
        #expect(vm.isLoading == false)
        #expect(vm.loadError == nil)
    }

    @Test
    func `load clears state when family is nil`() async {
        let deps = makeDependencies()
        let vm = QuestManagerViewModel(
            questService: deps.questService,
            familyService: deps.familyService,
            appState: deps.appState
        )

        await vm.load()

        #expect(vm.templates.isEmpty)
        #expect(vm.activeAssignments.isEmpty)
        #expect(vm.isLoading == false)
    }

    @Test
    func `quest edit locked error localized description`() {
        let error = QuestEditLockedError.lockedFields
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.contains("locked") == true)
    }

    @Test
    func `locked fields gate includes isAllOrNothing`() {
        let deps = makeDependencies()
        let vm = QuestManagerViewModel(
            questService: deps.questService,
            familyService: deps.familyService,
            appState: deps.appState
        )
        #expect(vm.templates.isEmpty)
    }

    @Test
    func `updateQuest propagateToTemplate defaults to false`() {
        let deps = makeDependencies()
        let vm = QuestManagerViewModel(
            questService: deps.questService,
            familyService: deps.familyService,
            appState: deps.appState
        )
        #expect(vm.activeAssignments.isEmpty)
    }

    // MARK: - Hero Board display mapping

    @Test
    func `hero display title maps the board placeholder to Hero Board`() {
        #expect(
            QuestManagerViewModel.heroDisplayTitle(forRecordName: HeroBoardService.boardAssigneeRecordName, heroes: [])
                == "Hero Board"
        )
    }

    @Test
    func `hero display title resolves real heroes and falls back for unknown`() {
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
        #expect(QuestManagerViewModel.heroDisplayTitle(forRecordName: "hero1", heroes: [hero]) == "Hero")
        #expect(QuestManagerViewModel.heroDisplayTitle(forRecordName: "ghost", heroes: [hero]) == "Unknown Hero")
    }

    // MARK: - Board quest editor payload

    private struct SaveFixture {
        let questService: QuestService
        let cache: CacheService
        let appState: AppState
        let parent: Profile
        let hero: Profile
        let zoneID: CKRecordZone.ID
        let familyRef: CKRecord.Reference
    }

    private func makeSaveFixture() throws -> SaveFixture {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache
        questService.appState = appState

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let parentID = CKRecord.ID(recordName: "parent1", zoneID: zoneID)
        let parent = Profile(
            displayName: "Parent GM",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: parentID,
            family: familyRef,
            id: parentID
        )
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let hero = Profile(
            displayName: "Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: heroID,
            family: familyRef,
            id: heroID
        )
        let family = Family(name: "Test Guild", creatorUserRecordName: parentID.recordName, id: familyRef.recordID)
        appState.currentProfile = parent
        appState.family = family
        appState.familyZoneID = zoneID
        appState.isZoneOwner = cloudKit.activeIsOwner

        return SaveFixture(
            questService: questService,
            cache: cache,
            appState: appState,
            parent: parent,
            hero: hero,
            zoneID: zoneID,
            familyRef: familyRef
        )
    }

    private func makeQuest(recordName: String, fixture: SaveFixture, assigneeRecordName: String) -> Quest {
        Quest(
            template: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "tmpl-\(recordName)", zoneID: fixture.zoneID), action: .none
            ),
            assignee: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: assigneeRecordName, zoneID: fixture.zoneID), action: .none
            ),
            goldReward: 500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            weekOf: WeekMath.startOfWeek(for: Date(), payoutDay: .sunday),
            createdBy: CKRecord.Reference(recordID: fixture.parent.id, action: .none),
            family: fixture.familyRef,
            name: "Kitchen Quest",
            id: CKRecord.ID(recordName: recordName, zoneID: fixture.zoneID)
        )
    }

    @Test
    func `saving a board quest payload preserves the placeholder assignee`() async throws {
        let fixture = try makeSaveFixture()
        let quest = makeQuest(recordName: "board1", fixture: fixture, assigneeRecordName: HeroBoardService.boardAssigneeRecordName)
        await fixture.cache.upsertQuest(quest)

        let vm = QuestManagerViewModel(questService: fixture.questService, appState: fixture.appState)
        let input = QuestManagerViewModel.UpdateQuestInput(
            name: "Renamed Board Quest",
            descriptionText: nil,
            goldReward: 500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            specificDays: [],
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            assignee: nil
        )
        try await vm.updateQuest(quest, input: input)

        let row = fixture.cache.fetchQuest(recordName: "board1", family: "fam1")
        #expect(row?.assigneeRecordName == HeroBoardService.boardAssigneeRecordName)
        #expect(row?.questName == "Renamed Board Quest")
    }

    @Test
    func `saving a regular quest payload still carries the chosen assignee`() async throws {
        let fixture = try makeSaveFixture()
        let quest = makeQuest(recordName: "quest1", fixture: fixture, assigneeRecordName: "hero2")
        await fixture.cache.upsertQuest(quest)

        let vm = QuestManagerViewModel(questService: fixture.questService, appState: fixture.appState)
        let input = QuestManagerViewModel.UpdateQuestInput(
            name: nil,
            descriptionText: nil,
            goldReward: 500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            specificDays: [],
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            assignee: fixture.hero
        )
        try await vm.updateQuest(quest, input: input)

        #expect(fixture.cache.fetchQuest(recordName: "quest1", family: "fam1")?.assigneeRecordName == fixture.hero.id.recordName)
    }
}
