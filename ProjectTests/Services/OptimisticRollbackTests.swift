//
//  OptimisticRollbackTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
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
}
