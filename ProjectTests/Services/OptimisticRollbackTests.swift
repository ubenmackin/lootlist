//
//  OptimisticRollbackTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData
import Testing

@MainActor
struct OptimisticRollbackTests {
    // MARK: - Mock Infrastructure

    private enum MockError: Error, Equatable {
        case saveFailed
    }

    /// Subclass of `CloudKitService` that always throws on `save`.
    /// Used to exercise the standard rollback (non-concurrent-edit) path.
    private final class FailingCloudKitService: CloudKitService {
        override func save<T: CloudKitRecord>(
            _: T,
            in _: CKRecordZone.ID? = nil,
            using _: CKDatabase? = nil
        ) async throws -> T {
            throw MockError.saveFailed
        }

        override func delete(
            _: CKRecord.ID,
            in _: CKRecordZone.ID? = nil,
            using _: CKDatabase? = nil
        ) async throws {
            throw MockError.saveFailed
        }
    }

    /// Subclass of `CloudKitService` that succeeds for the first N `save`
    /// calls, then throws on subsequent saves.  Needed for multi-step
    /// mutations (e.g., `assignQuickQuest`) where intermediate saves such
    /// as `createTemplate` + `deactivateTemplate` must succeed before the
    /// final quest save is made to fail.
    private final class FailingAfterNSavesCloudKitService: CloudKitService {
        private var saveCount = 0
        private let failAfterSaveCount: Int

        init(zoneID: CKRecordZone.ID, failAfterSaveCount: Int) {
            self.failAfterSaveCount = failAfterSaveCount
            super.init(zoneID: zoneID)
        }

        override func save<T: CloudKitRecord>(
            _ model: T,
            in zoneID: CKRecordZone.ID? = nil,
            using db: CKDatabase? = nil
        ) async throws -> T {
            saveCount += 1
            if saveCount > failAfterSaveCount {
                throw MockError.saveFailed
            }
            return try await super.save(model, in: zoneID, using: db)
        }
    }

    /// Subclass of `CloudKitService` that fails every `save` with
    /// `CloudKitServiceError.notFound` — the exact error CloudKitService wraps
    /// `CKError.unknownItem` into when a record was deleted on the server
    /// while a mutation was in flight. `fetch` fails the same way, matching
    /// the real server state after a concurrent delete.
    private final class NotFoundCloudKitService: CloudKitService {
        override func save<T: CloudKitRecord>(
            _: T,
            in _: CKRecordZone.ID? = nil,
            using _: CKDatabase? = nil
        ) async throws -> T {
            throw CloudKitServiceError.notFound("22")
        }

        override func fetch<T: CloudKitRecord>(
            _: T.Type,
            id _: CKRecord.ID,
            using _: CKDatabase? = nil
        ) async throws -> T {
            throw CloudKitServiceError.notFound("22")
        }
    }

    // MARK: - Shared Fixtures

    private func makeZoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
    }

    private func makeFamilyRef(_ zoneID: CKRecordZone.ID) -> CKRecord.Reference {
        CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID),
            action: .none
        )
    }

    private func makeParent(_ zoneID: CKRecordZone.ID) -> Profile {
        let userID = CKRecord.ID(recordName: "parent1", zoneID: zoneID)
        return Profile(
            displayName: "Parent GM",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: userID,
            family: makeFamilyRef(zoneID)
        )
    }

    private func makeHero(_ zoneID: CKRecordZone.ID) -> Profile {
        let userID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        return Profile(
            displayName: "Child Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: userID,
            family: makeFamilyRef(zoneID),
            id: userID
        )
    }

    private func makeFamily(_ zoneID: CKRecordZone.ID) -> Family {
        Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
    }

    // MARK: - 1. assignQuest invalidates on save failure ()

    @Test
    func `quest service assign quest invalidates on save failure`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let xpService = XPService(cloudKit: cloudKit, cacheService: cache)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        let familyRef = makeFamilyRef(zoneID)
        let parent = makeParent(zoneID)
        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)

        let templateID = CKRecord.ID(recordName: "tmpl1", zoneID: zoneID)
        let template = QuestTemplate(
            name: "Guard Duty",
            description: "Stand watch at the gate",
            defaultGold: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            createdBy: familyRef,
            family: familyRef,
            id: templateID
        )
        cloudKit.seedMockRecords([template])

        // Cache starts empty of quests.
        #expect(cache.fetchQuests(family: family.id.recordName).isEmpty)

        // Attempt -- save will fail.
        do {
            _ = try await questService.assignQuest(
                template: template,
                assignee: hero,
                weekOf: WeekMath.mondayOfWeek(for: Date()),
                createdBy: parent,
                family: family
            )
            #expect(Bool(false), "Expected save to throw")
        } catch {
            #expect(error is MockError)
        }

        // Rollback: optimistically-written quest must be invalidated.
        #expect(
            cache.fetchQuests(family: family.id.recordName).isEmpty,
            "assignQuest must invalidate the quest from cache after save failure"
        )
    }

    // MARK: - 2. updateQuest restores snapshot on save failure ()

    @Test
    func `quest service update quest restores snapshot on save failure`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let xpService = XPService(cloudKit: cloudKit, cacheService: cache)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        let familyRef = makeFamilyRef(zoneID)
        let hero = makeHero(zoneID)
        let monday = WeekMath.mondayOfWeek(for: Date())
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)

        // Seed the original quest in cache.
        let originalQuest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "Original Quest",
            id: questID
        )
        cache.upsertQuest(originalQuest)

        // Mutate the quest.
        var updatedQuest = originalQuest
        updatedQuest.name = "Modified Quest"
        updatedQuest.goldReward = 99.0

        // Attempt update -- save will fail.
        do {
            _ = try await questService.updateQuest(updatedQuest)
            #expect(Bool(false), "Expected save to throw")
        } catch {
            #expect(error is MockError)
        }

        // Rollback: cache must hold the pre-mutation snapshot.
        let cached = cache.fetchQuests(family: familyRef.recordID.recordName)
            .first(where: { $0.recordName == questID.recordName })
        #expect(cached != nil, "Quest must be restored from snapshot after save failure")
        let restored = try #require(cached?.toQuest(zoneID: zoneID))
        #expect(
            restored.name == "Original Quest",
            "Cache must have pre-mutation quest name after rollback"
        )
        #expect(
            restored.goldReward == 10.0,
            "Cache must have pre-mutation gold after rollback"
        )
    }

    // MARK: - 3. markComplete invalidates on save failure ()

    @Test
    func `quest service mark complete invalidates on save failure`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let xpService = XPService(cloudKit: cloudKit, cacheService: cache)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        let familyRef = makeFamilyRef(zoneID)
        let family = makeFamily(zoneID)
        let hero = makeHero(zoneID)
        let monday = WeekMath.mondayOfWeek(for: Date())
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)

        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 15.0,
            xpReward: 30,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "Complete Dragon",
            id: questID
        )

        // inside markComplete.
        cloudKit.seedMockRecords([quest])

        #expect(cache.fetchQuestCompletions(family: family.id.recordName).isEmpty)

        // Attempt -- save will fail.
        do {
            _ = try await questService.markComplete(quest: quest, by: hero)
            #expect(Bool(false), "Expected save to throw")
        } catch {
            #expect(error is MockError)
        }

        // Rollback: optimistically-written completion must be invalidated.
        #expect(
            cache.fetchQuestCompletions(family: family.id.recordName).isEmpty,
            "markComplete must invalidate the completion from cache after save failure"
        )
    }

    // MARK: - 4. assignQuickQuest invalidates both quest and template on save failure

    @Test
    func `quest service assign quick quest invalidates both on save failure`() async throws {
        let zoneID = makeZoneID()
        // createTemplate (save 1) and deactivateTemplate (save 2) must succeed;
        // the quest save (save 3) is where we inject the failure.
        let cloudKit = FailingAfterNSavesCloudKitService(
            zoneID: zoneID,
            failAfterSaveCount: 2
        )
        let cache = try CacheService(inMemory: true)
        let xpService = XPService(cloudKit: cloudKit, cacheService: cache)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        let family = makeFamily(zoneID)
        let parent = makeParent(zoneID)
        let hero = makeHero(zoneID)

        #expect(cache.fetchQuests(family: family.id.recordName).isEmpty)
        #expect(cache.fetchQuestTemplates(family: family.id.recordName).isEmpty)

        // Attempt -- first two saves succeed, quest save fails.
        do {
            _ = try await questService.assignQuickQuest(
                name: "Quick Task",
                description: "Do it fast",
                assignee: hero,
                goldReward: 5.0,
                xpReward: 10,
                weekOf: WeekMath.mondayOfWeek(for: Date()),
                createdBy: parent,
                family: family
            )
            #expect(Bool(false), "Expected save to throw")
        } catch {
            #expect(error is MockError)
        }

        // Rollback: both quest AND orphaned template invalidated.
        #expect(
            cache.fetchQuests(family: family.id.recordName).isEmpty,
            "assignQuickQuest must invalidate the quest on save failure"
        )
        #expect(
            cache.fetchQuestTemplates(family: family.id.recordName).isEmpty,
            "assignQuickQuest must invalidate the orphaned template on save failure"
        )
    }

    // MARK: - 5. XPService.addXP rolls back on save failure

    @Test
    func `xp service add XP rolls back on save failure`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let xpService = XPService(cloudKit: cloudKit, cacheService: cache)

        let hero = makeHero(zoneID)
        var heroWithXP = hero
        heroWithXP.xp = 100
        heroWithXP.level = 1
        cache.upsertProfile(heroWithXP)

        // Attempt -- save will fail; snapshot is restored.
        let returned = try await xpService.addXP(50, to: heroWithXP)

        // Returned profile is the rolled-back value.
        #expect(
            returned.xp == 100,
            "addXP must return rolled-back XP on save failure"
        )
        #expect(
            returned.level == 1,
            "addXP must return rolled-back level on save failure"
        )

        // Cache is also rolled back to the pre-mutation snapshot.
        let cached = cache.fetchProfile(recordName: hero.id.recordName)
        #expect(
            cached != nil,
            "Profile must be restored from snapshot after save failure"
        )
        #expect(
            cached?.xpTotal == 100,
            "Cache must have pre-mutation XP after rollback"
        )
        #expect(
            cached?.level == 1,
            "Cache must have pre-mutation level after rollback"
        )
    }

    // MARK: - 6. TreasuryService.createAllowancePeriod invalidates on save failure

    @Test
    func `treasury service create allowance period rolls back on save failure`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache)

        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)
        let monday = WeekMath.mondayOfWeek(for: Date())

        // Cache starts empty of allowance periods.
        #expect(cache.fetchAllowancePeriods(family: family.id.recordName).isEmpty)

        // Attempt -- save will fail.
        do {
            _ = try await treasury.getOrCreateAllowancePeriod(
                profile: hero,
                weekOf: monday,
                family: family
            )
            #expect(Bool(false), "Expected save to throw")
        } catch {
            #expect(error is MockError)
        }

        // Rollback: new period invalidated from cache (no prior snapshot).
        #expect(
            cache.fetchAllowancePeriods(family: family.id.recordName).isEmpty,
            "createAllowancePeriod must invalidate the new period on save failure"
        )
    }

    // MARK: - 7. TreasuryService.updateAllowance restores snapshot on save failure

    @Test
    func `treasury service update allowance rolls back on save failure`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache)

        let hero = makeHero(zoneID)
        let familyRef = makeFamilyRef(zoneID)
        let monday = WeekMath.mondayOfWeek(for: Date())
        let periodID = CKRecord.ID(recordName: "period1", zoneID: zoneID)

        // Seed original allowance period in cache.
        let originalPeriod = AllowancePeriod(
            weekOf: monday,
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            questsTotal: 5,
            family: familyRef,
            id: periodID
        )
        cache.upsertAllowancePeriod(originalPeriod)

        // Attempt update with modified values -- save will fail.
        do {
            _ = try await treasury.updateAllowance(
                period: originalPeriod,
                totalEarned: 999.0,
                questsCompleted: 10
            )
            #expect(Bool(false), "Expected save to throw")
        } catch {
            #expect(error is MockError)
        }

        // Rollback: cache holds the pre-mutation snapshot.
        let cached = cache.fetchAllowancePeriods(family: familyRef.recordID.recordName)
            .first(where: { $0.recordName == periodID.recordName })
        #expect(
            cached != nil,
            "Allowance period must be restored from snapshot after save failure"
        )
        let restored = try #require(cached?.toAllowancePeriod(zoneID: zoneID))
        #expect(
            restored.totalEarned == originalPeriod.totalEarned,
            "Cache must have pre-mutation totalEarned after rollback"
        )
        #expect(
            restored.questsCompleted == originalPeriod.questsCompleted,
            "Cache must have pre-mutation questsCompleted after rollback"
        )
    }

    // MARK: - 8. NotificationService.updatePreference invalidates on save failure

    @Test
    func `notification service update preference invalidates on save failure`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        appState.currentProfile = makeHero(zoneID)
        appState.family = makeFamily(zoneID)

        let notificationService = NotificationService(
            cloudKit: cloudKit,
            appState: appState,
            cacheService: cache
        )

        // Cache starts empty of notification preferences.
        #expect(cache.fetchNotificationPreferences(profileRecordName: "hero1").isEmpty)

        // Attempt -- save will fail.
        do {
            _ = try await notificationService.updatePreference(
                event: .questAssigned,
                enabled: false
            )
            #expect(Bool(false), "Expected save to throw")
        } catch {
            #expect(error is MockError)
        }

        // Rollback: new preference invalidated from cache (no prior snapshot).
        #expect(
            cache.fetchNotificationPreferences(profileRecordName: "hero1").isEmpty,
            "updatePreference must invalidate the new preference on save failure"
        )
    }

    // MARK: - 9. FamilyService.updateFamilyName restores snapshot on save failure

    @Test
    func `family service update family rolls back on save failure`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let xpService = XPService(cloudKit: cloudKit, cacheService: cache)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        let familyService = FamilyService(
            cloudKit: cloudKit,
            appState: appState,
            questService: questService,
            cacheService: cache
        )

        let family = makeFamily(zoneID)
        cache.upsertFamily(family)
        appState.family = family
        appState.currentProfile = makeParent(zoneID)

        // Attempt -- save will fail.
        do {
            _ = try await familyService.updateFamilyName(
                family: family,
                newName: "New Guild Name"
            )
            #expect(Bool(false), "Expected save to throw")
        } catch let error as FamilyServiceError {
            #expect(error == .persistenceFailed("Could not update family name: saveFailed"))
        }

        // Rollback: cache holds the pre-mutation snapshot.
        let cached = cache.fetchFamily(recordName: family.id.recordName)
        #expect(
            cached != nil,
            "Family must be restored from snapshot after save failure"
        )
        let restored = try #require(cached?.toFamily(zoneID: zoneID))
        #expect(
            restored.name == "Test Guild",
            "Cache must have pre-mutation family name after rollback"
        )

        #expect(
            appState.family?.name == "Test Guild",
            "AppState must have pre-mutation family name after rollback"
        )
    }

    // MARK: - 10. QuestService.verify restores snapshot on save failure ()

    @Test
    func `quest service verify rolls back on save failure`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let xpService = XPService(cloudKit: cloudKit, cacheService: cache)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        let familyRef = makeFamilyRef(zoneID)
        let parent = makeParent(zoneID)
        let monday = WeekMath.mondayOfWeek(for: Date())
        let questRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let heroRef = CKRecord.Reference(recordID: makeHero(zoneID).id, action: .none)
        let completionID = CKRecord.ID(recordName: "questLog1", zoneID: zoneID)

        let originalCompletion = QuestCompletion(
            quest: questRef,
            completedBy: heroRef,
            approvalMode: .parentVerify,
            weekOf: monday,
            family: familyRef,
            id: completionID
        )
        cache.upsertQuestCompletion(originalCompletion)

        let familyRecordName = familyRef.recordID.recordName

        // Confirm pre-mutation state: pending, no verifier.
        let seeded = cache.fetchQuestCompletions(family: familyRecordName)
            .first(where: { $0.recordName == completionID.recordName })
        let seededCompletion = try #require(
            seeded?.toQuestCompletion(zoneID: zoneID)
        )
        #expect(seededCompletion.verificationStatus == .pending)
        #expect(seededCompletion.verifiedBy == nil)

        do {
            _ = try await questService.verify(questLog: originalCompletion, by: parent)
            #expect(Bool(false), "Expected save to throw")
        } catch {
            #expect(error is MockError)
        }

        // Rollback: cache must hold the pre-mutation snapshot.
        let cached = cache.fetchQuestCompletions(family: familyRecordName)
            .first(where: { $0.recordName == completionID.recordName })
        #expect(
            cached != nil,
            "QuestLog must be restored from snapshot after save failure"
        )
        let restored = try #require(cached?.toQuestCompletion(zoneID: zoneID))
        #expect(
            restored.verificationStatus == .pending,
            "Cache must have pre-mutation pending verificationStatus after rollback"
        )
        #expect(
            restored.verifiedBy == nil,
            "Cache must have pre-mutation nil verifiedBy after rollback"
        )
    }

    // MARK: - 11. AchievementService.award invalidates cache on save failure

    @Test
    func `achievement service award invalidates cache on save failure`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let service = AchievementService(cloudKit: cloudKit, cacheService: cache)

        let familyRef = makeFamilyRef(zoneID)
        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)
        let achievement = Achievement(
            name: "Test Achievement",
            description: "Test Description",
            iconSystemName: "star",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: familyRef
        )

        do {
            _ = try await service.award(achievement, to: hero, family: family)
            #expect(Bool(false), "Expected save to throw")
        } catch {
            #expect(error is MockError)
        }

        let cached = cache.fetchProfileAchievements(profileRecordName: hero.id.recordName)
        #expect(cached.isEmpty, "ProfileAchievement must be invalidated after save failure for new award")
    }

    // MARK: - 12. In-flight mutation registry guards optimistic writes from background sync (M1)

    private func makeOptimisticQuest(_ zoneID: CKRecordZone.ID) -> (quest: Quest, questID: CKRecord.ID) {
        let familyRef = makeFamilyRef(zoneID)
        let hero = makeHero(zoneID)
        let monday = WeekMath.mondayOfWeek(for: Date())
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)
        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "Original Quest",
            id: questID
        )
        return (quest, questID)
    }

    /// Reads a quest through a FRESH `ModelContext` so the assertion reflects
    /// the committed store state, not a possibly-stale registered object in the
    /// mainContext (cross-context propagation is not guaranteed — TASK-006).
    private func fetchCachedQuest(
        _ container: ModelContainer,
        recordName: String,
        zoneID: CKRecordZone.ID
    ) throws -> Quest? {
        let ctx = ModelContext(container)
        let descriptor = FetchDescriptor<QuestCache>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        return try ctx.fetch(descriptor).first?.toQuest(zoneID: zoneID)
    }

    @Test
    func `background batch upsert does not clobber optimistically-written in-flight row`() async throws {
        let zoneID = makeZoneID()
        let cache = try CacheService(inMemory: true)
        let container = try #require(cache.container)
        let registry = cache.inFlightRegistry
        let backgroundCache = BackgroundCacheActor(container: container, inFlightRegistry: registry)

        let (originalQuest, questID) = makeOptimisticQuest(zoneID)
        cache.upsertQuest(originalQuest)

        // Optimistic write: the author's in-flight values are now in the cache.
        var optimisticQuest = originalQuest
        optimisticQuest.name = "Optimistic Quest"
        optimisticQuest.goldReward = 99.0
        cache.upsertQuest(optimisticQuest)

        // The mutation is still in flight (local upsert → await cloudKit.save).
        await registry.register(questID.recordName)

        // A background sync arrives mid-mutation carrying stale server data.
        await backgroundCache.batchUpsertQuests(
            [originalQuest],
            familyRecordName: originalQuest.family.recordID.recordName
        )

        // The optimistically-written row must survive the sync untouched.
        let restored = try #require(
            try fetchCachedQuest(container, recordName: questID.recordName, zoneID: zoneID)
        )
        #expect(
            restored.name == "Optimistic Quest",
            "In-flight row must not be clobbered by a background batchUpsert"
        )
        #expect(
            restored.goldReward == 99.0,
            "In-flight row must keep the optimistic gold after a background batchUpsert"
        )
    }

    @Test
    func `background batch upsert applies normally after mutation deregisters`() async throws {
        let zoneID = makeZoneID()
        let cache = try CacheService(inMemory: true)
        let container = try #require(cache.container)
        let registry = cache.inFlightRegistry
        let backgroundCache = BackgroundCacheActor(container: container, inFlightRegistry: registry)

        let (originalQuest, questID) = makeOptimisticQuest(zoneID)
        cache.upsertQuest(originalQuest)

        var optimisticQuest = originalQuest
        optimisticQuest.name = "Optimistic Quest"
        optimisticQuest.goldReward = 99.0
        cache.upsertQuest(optimisticQuest)

        // The mutation is in flight, then settles (success or terminal failure):
        // the record is deregistered once the CloudKit save settles.
        await registry.register(questID.recordName)
        await registry.deregister(questID.recordName)

        // A sync arriving after deregistration applies server data normally.
        await backgroundCache.batchUpsertQuests(
            [originalQuest],
            familyRecordName: originalQuest.family.recordID.recordName
        )

        let restored = try #require(
            try fetchCachedQuest(container, recordName: questID.recordName, zoneID: zoneID)
        )
        #expect(
            restored.name == "Original Quest",
            "Sync writes must apply normally after the mutation deregisters"
        )
        #expect(
            restored.goldReward == 10.0,
            "Sync writes must restore server gold after the mutation deregisters"
        )
    }

    @Test
    func `purge missing does not delete a row under an active optimistic mutation`() async throws {
        let zoneID = makeZoneID()
        let cache = try CacheService(inMemory: true)
        let container = try #require(cache.container)
        let registry = cache.inFlightRegistry
        let backgroundCache = BackgroundCacheActor(container: container, inFlightRegistry: registry)

        let familyRef = makeFamilyRef(zoneID)
        let monday = WeekMath.mondayOfWeek(for: Date())
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let heroRef = CKRecord.Reference(recordID: makeHero(zoneID).id, action: .none)

        // A quest whose save has settled — not under any optimistic mutation.
        let settledID = CKRecord.ID(recordName: "quest2", zoneID: zoneID)
        let settledQuest = Quest(
            template: templateRef,
            assignee: heroRef,
            goldReward: 5.0,
            xpReward: 10,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "Settled Quest",
            id: settledID
        )
        cache.upsertQuest(settledQuest)

        // A quest under an active optimistic mutation: the local cache write is
        // done but the CloudKit save has not settled (or settled and the
        // author's post-save re-upsert has not deregistered yet).
        let (optimisticQuest, optimisticID) = makeOptimisticQuest(zoneID)
        cache.upsertQuest(optimisticQuest)
        await registry.register(optimisticID.recordName)

        // Full-sync purge: `validRecordNames` is a CloudKit query snapshot
        // taken before either quest existed, so neither appears in it.
        await backgroundCache.purgeMissingQuests(
            validRecordNames: [],
            familyRecordName: familyRef.recordID.recordName
        )

        // The row under an active optimistic mutation must survive the purge.
        let survived = try #require(
            try fetchCachedQuest(container, recordName: optimisticID.recordName, zoneID: zoneID)
        )
        #expect(
            survived.name == "Original Quest",
            "A row under an active optimistic mutation must survive a purgeMissing pass"
        )

        // The deregistered row is purged normally.
        #expect(
            try fetchCachedQuest(container, recordName: settledID.recordName, zoneID: zoneID) == nil,
            "A deregistered row absent from the server snapshot must be purged"
        )
    }

    // MARK: - 13. Incremental-sync deletion skips rows under an active optimistic mutation (M1b)

    @Test
    func `delete record does not delete a row under an active optimistic mutation`() async throws {
        let zoneID = makeZoneID()
        let cache = try CacheService(inMemory: true)
        let container = try #require(cache.container)
        let registry = cache.inFlightRegistry
        let backgroundCache = BackgroundCacheActor(container: container, inFlightRegistry: registry)

        let (optimisticQuest, questID) = makeOptimisticQuest(zoneID)
        cache.upsertQuest(optimisticQuest)

        // The mutation is still in flight (local upsert → await cloudKit.save).
        await registry.register(questID.recordName)

        // An incremental sync delivers a server-side deletion for the same
        // record while the mutation is in flight.
        await backgroundCache.deleteRecord(recordName: questID.recordName, type: .quest)

        // The optimistically-written row must survive the sync deletion — the
        // author's rollback (or post-save re-upsert) reconciles it once the
        // save settles, and deleting it first would let the rollback
        // resurrect a record that no longer exists server-side.
        let survived = try #require(
            try fetchCachedQuest(container, recordName: questID.recordName, zoneID: zoneID)
        )
        #expect(
            survived.name == "Original Quest",
            "A row under an active optimistic mutation must survive a sync deletion"
        )

        // Once the save settles (deregister), the deletion applies normally.
        await registry.deregister(questID.recordName)
        await backgroundCache.deleteRecord(recordName: questID.recordName, type: .quest)
        #expect(
            try fetchCachedQuest(container, recordName: questID.recordName, zoneID: zoneID) == nil,
            "A deregistered row with a server-side deletion must be deleted"
        )
    }

    // MARK: - 14. .notFound save failure during a concurrent delete invalidates, never resurrects (no zombie quest)

    @Test
    func `notFound save failure during concurrent delete invalidates instead of resurrecting snapshot`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = NotFoundCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let container = try #require(cache.container)
        let xpService = XPService(cloudKit: cloudKit, cacheService: cache)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        let familyRef = makeFamilyRef(zoneID)
        let hero = makeHero(zoneID)
        let monday = WeekMath.mondayOfWeek(for: Date())
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)

        // Seed the original quest in cache — the pre-mutation snapshot.
        let originalQuest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "Original Quest",
            id: questID
        )
        cache.upsertQuest(originalQuest)

        // Another device deletes the quest on the server; an incremental sync
        // delivers that deletion WHILE our optimistic mutation is in flight.
        // The in-flight registry guard (M1b) keeps the sync's hands off the
        // optimistically-written row.
        let registry = cache.inFlightRegistry
        let backgroundCache = BackgroundCacheActor(container: container, inFlightRegistry: registry)
        await registry.register(questID.recordName)
        await backgroundCache.deleteRecord(recordName: questID.recordName, type: .quest)
        let survivedSync = try #require(
            try fetchCachedQuest(container, recordName: questID.recordName, zoneID: zoneID)
        )
        #expect(
            survivedSync.name == "Original Quest",
            "In-flight rows must survive a sync deletion (M1b guard)"
        )

        // The mutation's save settles with `.notFound`: the record no longer
        // exists server-side. The rollback must invalidate — never restore the
        // pre-mutation snapshot, which would resurrect a zombie quest.
        var updatedQuest = originalQuest
        updatedQuest.name = "Modified Quest"
        updatedQuest.goldReward = 99.0

        do {
            _ = try await questService.updateQuest(updatedQuest)
            #expect(Bool(false), "Expected save to throw")
        } catch {
            #expect(error is CloudKitServiceError)
        }

        // No zombie row: the cache must not contain the pre-mutation snapshot.
        #expect(
            cache.fetchQuests(family: familyRef.recordID.recordName).isEmpty,
            "A .notFound save failure during a concurrent delete must invalidate, not restore the snapshot"
        )
    }
}
