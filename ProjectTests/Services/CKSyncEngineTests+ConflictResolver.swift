//
//  CKSyncEngineTests+ConflictResolver.swift
//  LootList
//
//  Created by Ben Mackin on 8/14/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData
import Testing

extension CKSyncEngineTests {
    // MARK: - Conflict Resolver & Local Edit Field Preservation Tests

    @Test
    func `conflict resolver preserves local field edits on quest conflict while merging xpBanked`() async throws {
        let cache = try CacheService(inMemory: true)
        let bgActor = try BackgroundCacheActor(container: #require(cache.container))
        let resolver = CKSyncConflictResolver(cacheService: cache, backgroundCache: bgActor)

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let questID = CKRecord.ID(recordName: "quest_conflict", zoneID: zoneID)
        let tmplRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "tpl1", zoneID: zoneID), action: .none)
        let heroRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none)

        let clientQuest = Quest(
            template: tmplRef,
            assignee: heroRef,
            goldReward: 25.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: heroRef,
            family: familyRef,
            name: "Local Edited Name",
            descriptionText: "Local Edited Description",
            xpBanked: 10,
            id: questID
        )
        let clientRecord = clientQuest.toRecord()

        var serverQuest = clientQuest
        serverQuest.name = "Server Old Name"
        serverQuest.goldReward = 5.0
        serverQuest.xpBanked = 30
        let serverRecord = serverQuest.toRecord()

        let ckError = CKError(
            .serverRecordChanged,
            userInfo: [
                CKRecordChangedErrorServerRecordKey: serverRecord,
                CKRecordChangedErrorClientRecordKey: clientRecord
            ]
        )

        let resolved = try #require(await resolver.resolveFailedSave(record: clientRecord, error: ckError))
        #expect(resolved["name"] as? String == "Local Edited Name")
        #expect(resolved["goldReward"] as? Double == 5.0)
        #expect(resolved["xpBanked"] as? Int == 30)

        let cached = try #require(cache.fetchQuest(recordName: questID.recordName, family: "fam1"))
        #expect(cached.questName == "Local Edited Name")
        #expect(cached.goldReward == 5.0)
        #expect(cached.xpBanked == 30)
    }

    @Test
    func `conflict resolver preserves local field edits on profile conflict while merging xp`() async throws {
        let cache = try CacheService(inMemory: true)
        let bgActor = try BackgroundCacheActor(container: #require(cache.container))
        let resolver = CKSyncConflictResolver(cacheService: cache, backgroundCache: bgActor)

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let heroID = CKRecord.ID(recordName: "hero_conflict", zoneID: zoneID)

        var clientProfile = Profile(
            displayName: "Local Hero Name",
            avatarPresetID: "preset_dragon",
            role: .hero,
            iCloudUserID: heroID,
            family: familyRef,
            payoutPolicy: .realTime,
            payoutDay: .friday,
            id: heroID
        )
        clientProfile.xp = 50
        let clientRecord = clientProfile.toRecord()

        var serverProfile = clientProfile
        serverProfile.displayName = "Server Old Name"
        serverProfile.avatarPresetID = "preset_default"
        serverProfile.xp = 120
        let serverRecord = serverProfile.toRecord()

        let ckError = CKError(
            .serverRecordChanged,
            userInfo: [
                CKRecordChangedErrorServerRecordKey: serverRecord,
                CKRecordChangedErrorClientRecordKey: clientRecord
            ]
        )

        let resolved = try #require(await resolver.resolveFailedSave(record: clientRecord, error: ckError))
        #expect(resolved["displayName"] as? String == "Local Hero Name")
        #expect(resolved["avatarPresetID"] as? String == "preset_dragon")
        #expect(resolved["xp"] as? Int == 120)

        let cached = try #require(cache.fetchProfile(recordName: heroID.recordName, family: "fam1"))
        #expect(cached.displayName == "Local Hero Name")
        #expect(cached.avatarName == "preset_dragon")
        #expect(cached.xpTotal == 120)
    }

    @Test
    func `fetchedDatabaseChanges zone deletion purges both main and background caches`() async throws {
        let cache = try CacheService(inMemory: true)
        let container = try #require(cache.container)
        let bgActor = BackgroundCacheActor(container: container)
        let resolver = CKSyncConflictResolver(cacheService: cache, backgroundCache: bgActor)
        let delegate = CKSyncEngineDelegateHandler(backgroundCache: bgActor, conflictResolver: resolver, cacheService: cache)

        let family = Family(
            name: "Deleted Zone Family",
            createdBy: CKRecord.ID(recordName: "gm1", zoneID: zoneID),
            id: CKRecord.ID(recordName: zoneID.zoneName, zoneID: zoneID)
        )
        cache.upsertFamily(family)

        #expect(cache.fetchFamily(recordName: zoneID.zoneName) != nil)

        await delegate.handleDatabaseZoneDeletion(zoneID: zoneID)

        #expect(cache.fetchFamily(recordName: zoneID.zoneName) == nil)
    }

    @Test
    func `mutations create records with custom zoneID`() async throws {
        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        appState.cacheService = cache

        let parentID = CKRecord.ID(recordName: "parent1", zoneID: zoneID)
        let familyID = CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
        let parent = Profile(
            displayName: "Parent GM",
            role: .guildMaster,
            iCloudUserID: parentID,
            family: familyRef,
            id: parentID
        )
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let hero = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: heroID,
            family: familyRef,
            id: heroID
        )
        let family = Family(
            name: "Zone Guild",
            createdBy: parentID,
            id: familyID
        )
        appState.currentProfile = parent
        appState.isZoneOwner = true

        let xpService = XPService(cloudKit: ck, cacheService: cache, appState: appState)
        let questService = QuestService(cloudKit: ck, xpService: xpService, cacheService: cache, appState: appState)
        let template = try await questService.createTemplate(
            name: "Template 1",
            description: "Desc",
            defaultGold: 10,
            xpReward: 20,
            schedule: .weeklyFlexible,
            createdBy: parent,
            family: family
        )
        #expect(template.id.zoneID == zoneID)

        let quest = try await questService.assignQuest(
            template: template,
            assignee: hero,
            weekOf: Date(),
            createdBy: parent,
            family: family
        )
        #expect(quest.id.zoneID == zoneID)

        appState.currentProfile = hero
        let completion = try await questService.markComplete(quest: quest, by: hero)
        #expect(completion.id.zoneID == zoneID)
        appState.currentProfile = parent

        let treasuryService = TreasuryService(cloudKit: ck, cacheService: cache, appState: appState)
        let period = try await treasuryService.getOrCreateAllowancePeriod(profile: hero, weekOf: WeekMath.mondayOfWeek(for: Date()), family: family)
        #expect(period.id.zoneID == zoneID)

        let spendingService = SpendingService(cloudKit: ck, cacheService: cache, appState: appState)
        let ledgerManual = try await spendingService.logManual(profile: hero, family: family, familyRecordName: familyID.recordName, description: "Test", amount: 5)
        #expect(ledgerManual.id.zoneID == zoneID)

        let achievementService = AchievementService(cloudKit: ck, cacheService: cache, appState: appState)
        cache.markCacheFresh(familyRecordName: family.id.recordName, type: .achievement)
        try await achievementService.seedDefaultAchievements(family: family)
        let definitions = try await achievementService.fetchAllDefinitions(family: family)
        #expect(!definitions.isEmpty)
        #expect(definitions.allSatisfy { $0.id.zoneID == zoneID })

        if let firstDef = definitions.first {
            let awarded = try await achievementService.award(firstDef, to: hero, family: family)
            #expect(awarded.id.zoneID == zoneID)
        }
    }

    // MARK: - System Fields & Additive Merge Tests

    @Test
    func `record bridge preserves encodedSystemFields when building CKRecord`() throws {
        let cache = try CacheService(inMemory: true)
        let questID = CKRecord.ID(recordName: "quest_system_fields", zoneID: zoneID)
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)

        // Create a server record with system fields
        let serverRecord = CKRecord(recordType: Quest.recordType, recordID: questID)
        serverRecord["name"] = "Original Server Quest" as CKRecordValue
        let encodedData = serverRecord.encodedSystemFields
        #expect(!encodedData.isEmpty)

        // Hydrate domain model from server record
        var quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tpl1", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none),
            goldReward: 10,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            weekOf: Date(),
            createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: "p1", zoneID: zoneID), action: .none),
            family: familyRef,
            name: "Updated Local Quest",
            id: questID
        )
        quest.encodedSystemFields = encodedData
        cache.upsertQuest(quest)

        let identity = ScopedRecordIdentity(
            databaseScope: .private,
            zoneID: questID.zoneID,
            recordID: questID,
            familyRecordName: "fam1"
        )
        let bridgedRecord = try #require(RecordBridge.record(for: identity, cacheService: cache))
        #expect(bridgedRecord.recordID == questID)
        #expect(bridgedRecord["name"] as? String == "Updated Local Quest")
    }

    @Test
    func `conflict resolver performs additive XP merge for offline earnings`() async throws {
        let cache = try CacheService(inMemory: true)
        let resolver = CKSyncConflictResolver(cacheService: cache)
        let profileID = CKRecord.ID(recordName: "hero_additive", zoneID: zoneID)
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)

        // Cached profile on device has lastSyncedXP = 100
        var baseline = Profile(displayName: "Hero", role: .hero, iCloudUserID: profileID, family: familyRef, id: profileID)
        baseline.xp = 100
        baseline.level = XPService.level(forXP: 100)
        cache.upsertProfile(baseline)

        // Now device earned +50 XP offline (client XP = 150)
        var clientProfile = baseline
        clientProfile.xp = 150
        clientProfile.level = XPService.level(forXP: 150)
        let clientRecord = clientProfile.toRecord()

        // Server concurrently earned +30 XP on another device (server XP = 130)
        let serverRecord = CKRecord(recordType: Profile.recordType, recordID: profileID)
        serverRecord["displayName"] = "Hero" as CKRecordValue
        serverRecord["role"] = UserRole.hero.rawValue as CKRecordValue
        serverRecord["xp"] = 130 as CKRecordValue
        serverRecord["level"] = XPService.level(forXP: 130) as CKRecordValue
        serverRecord["iCloudUserID"] = profileID.recordName as CKRecordValue
        serverRecord["family"] = familyRef as CKRecordValue
        serverRecord["isActive"] = true as CKRecordValue
        serverRecord["payoutPolicy"] = PayoutPolicy.perQuest.rawValue as CKRecordValue

        let serverChangedError = CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.serverRecordChanged.rawValue,
            userInfo: [CKRecordChangedErrorServerRecordKey: serverRecord]
        ))

        // Resolver should compute: clientDelta = 150 - 100 = 50
        // mergedXP = serverXP (130) + clientDelta (50) = 180
        let resolvedRecord = await resolver.resolveFailedSave(record: clientRecord, error: serverChangedError)
        let resolved = try #require(resolvedRecord)

        #expect(resolved["xp"] as? Int == 180)
        #expect(resolved["level"] as? Int == XPService.level(forXP: 180))

        let cachedProfile = cache.fetchProfile(recordName: profileID.recordName, family: "fam1")
        #expect(cachedProfile?.xpTotal == 180)
    }

    @Test
    func `achievement award generates deterministic composite recordID`() async throws {
        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        appState.cacheService = cache

        let familyID = CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        let family = Family(name: "Guild", createdBy: CKRecord.ID(recordName: "gm", zoneID: zoneID), id: familyID)
        let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
        let profileID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let profile = Profile(displayName: "Hero", role: .hero, iCloudUserID: profileID, family: familyRef, id: profileID)
        appState.currentProfile = profile

        let achievementService = AchievementService(cloudKit: ck, cacheService: cache, appState: appState)
        let achievementID = CKRecord.ID(recordName: "ach_first_quest", zoneID: zoneID)
        let achievement = Achievement(
            id: achievementID,
            name: "First Steps",
            description: "Desc",
            iconSystemName: "star",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: familyRef
        )

        let awarded1 = try await achievementService.award(achievement, to: profile, family: family)
        let awarded2 = try await achievementService.award(achievement, to: profile, family: family)

        let expectedRecordName = "\(profileID.recordName)_\(achievementID.recordName)"
        #expect(awarded1.id.recordName == expectedRecordName)
        #expect(awarded2.id.recordName == expectedRecordName)
        #expect(awarded1.id == awarded2.id)
    }

    @Test
    func `local XP edit does not corrupt ProfileCache lastSyncedXP baseline before conflict resolution`() async throws {
        let cache = try CacheService(inMemory: true)
        let resolver = CKSyncConflictResolver(cacheService: cache)
        let profileID = CKRecord.ID(recordName: "hero_baseline_test", zoneID: zoneID)
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)

        // 1. Initial server-sync hydration with baseline XP = 100 and system fields
        let initialServerRecord = CKRecord(recordType: Profile.recordType, recordID: profileID)
        initialServerRecord["displayName"] = "Hero" as CKRecordValue
        initialServerRecord["role"] = UserRole.hero.rawValue as CKRecordValue
        initialServerRecord["xp"] = 100 as CKRecordValue
        initialServerRecord["level"] = XPService.level(forXP: 100) as CKRecordValue
        initialServerRecord["iCloudUserID"] = profileID.recordName as CKRecordValue
        initialServerRecord["family"] = familyRef as CKRecordValue
        initialServerRecord["isActive"] = true as CKRecordValue
        initialServerRecord["payoutPolicy"] = PayoutPolicy.perQuest.rawValue as CKRecordValue

        var baselineProfile = try Profile(record: initialServerRecord)
        baselineProfile.encodedSystemFields = initialServerRecord.encodedSystemFields
        cache.upsertProfile(baselineProfile, isServerSync: true)

        let cachedAfterSync = try #require(cache.fetchProfile(recordName: profileID.recordName, family: "fam1"))
        #expect(cachedAfterSync.lastSyncedXP == 100)
        #expect(cachedAfterSync.xpTotal == 100)

        // 2. Local mutation adds +50 XP (local edit path, isServerSync defaults to false)
        var localProfile = baselineProfile
        localProfile.xp = 150
        localProfile.level = XPService.level(forXP: 150)
        cache.upsertProfile(localProfile, isServerSync: false)

        // Verify lastSyncedXP was NOT corrupted by the local edit
        let cachedAfterLocalEdit = try #require(cache.fetchProfile(recordName: profileID.recordName, family: "fam1"))
        #expect(cachedAfterLocalEdit.lastSyncedXP == 100)
        #expect(cachedAfterLocalEdit.xpTotal == 150)

        // 3. Concurrent server update earns +30 XP on another device (server XP = 130)
        let concurrentServerRecord = CKRecord(recordType: Profile.recordType, recordID: profileID)
        concurrentServerRecord["displayName"] = "Hero" as CKRecordValue
        concurrentServerRecord["role"] = UserRole.hero.rawValue as CKRecordValue
        concurrentServerRecord["xp"] = 130 as CKRecordValue
        concurrentServerRecord["level"] = XPService.level(forXP: 130) as CKRecordValue
        concurrentServerRecord["iCloudUserID"] = profileID.recordName as CKRecordValue
        concurrentServerRecord["family"] = familyRef as CKRecordValue
        concurrentServerRecord["isActive"] = true as CKRecordValue
        concurrentServerRecord["payoutPolicy"] = PayoutPolicy.perQuest.rawValue as CKRecordValue

        let clientRecord = localProfile.toRecord()
        let serverChangedError = CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.serverRecordChanged.rawValue,
            userInfo: [CKRecordChangedErrorServerRecordKey: concurrentServerRecord]
        ))

        // Resolver computes: clientDelta = 150 - 100 = 50
        // Merged XP = 130 + 50 = 180
        let resolvedRecord = await resolver.resolveFailedSave(record: clientRecord, error: serverChangedError)
        let resolved = try #require(resolvedRecord)

        #expect(resolved["xp"] as? Int == 180)
        #expect(resolved["level"] as? Int == XPService.level(forXP: 180))

        let cachedAfterConflict = try #require(cache.fetchProfile(recordName: profileID.recordName, family: "fam1"))
        #expect(cachedAfterConflict.xpTotal == 180)
        #expect(cachedAfterConflict.lastSyncedXP == 180)
    }

    @Test
    func `CKSyncEngineCoordinator setupEngines is idempotent`() {
        let ck = MockCloudKitService()
        let resolver = CKSyncConflictResolver()
        let delegate = CKSyncEngineDelegateHandler(conflictResolver: resolver)
        let coordinator = CKSyncEngineCoordinator(cloudKitService: ck, delegateHandler: delegate)

        let privateConfig = CKSyncEngine.Configuration(
            database: ck.container.privateCloudDatabase,
            stateSerialization: nil,
            delegate: delegate
        )
        let engine1 = CKSyncEngine(privateConfig)
        coordinator.privateSyncEngine = engine1

        // Calling initializeEngines should not overwrite existing engine instances
        coordinator.initializeEngines()
        #expect(coordinator.privateSyncEngine === engine1)
    }

    @Test
    func `resolveQuestConflict caps xpBanked at quest xpReward`() async throws {
        let cache = try CacheService(inMemory: true)
        let resolver = CKSyncConflictResolver(cacheService: cache)
        let questID = CKRecord.ID(recordName: "quest_capped_xp", zoneID: zoneID)
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let heroRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none)
        let tplRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "tpl1", zoneID: zoneID), action: .none)

        let serverRecord = CKRecord(recordType: Quest.recordType, recordID: questID)
        serverRecord["name"] = "Clean Room" as CKRecordValue
        serverRecord["xpReward"] = 50 as CKRecordValue
        serverRecord["xpBanked"] = 40 as CKRecordValue
        serverRecord["goldReward"] = 10.0 as CKRecordValue
        serverRecord["scheduleType"] = QuestSchedule.weeklyFlexible.rawValue as CKRecordValue
        serverRecord["weekOf"] = Date() as CKRecordValue
        serverRecord["family"] = familyRef as CKRecordValue
        serverRecord["assignee"] = heroRef as CKRecordValue
        serverRecord["template"] = tplRef as CKRecordValue
        serverRecord["createdBy"] = heroRef as CKRecordValue
        serverRecord["approvalMode"] = ApprovalMode.autoApprove.rawValue as CKRecordValue
        serverRecord["active"] = true as CKRecordValue

        let clientRecord = CKRecord(recordType: Quest.recordType, recordID: questID)
        clientRecord["name"] = "Clean Room" as CKRecordValue
        clientRecord["xpReward"] = 50 as CKRecordValue
        clientRecord["xpBanked"] = 70 as CKRecordValue // over-cap
        clientRecord["goldReward"] = 10.0 as CKRecordValue
        clientRecord["scheduleType"] = QuestSchedule.weeklyFlexible.rawValue as CKRecordValue
        clientRecord["weekOf"] = Date() as CKRecordValue
        clientRecord["family"] = familyRef as CKRecordValue
        clientRecord["assignee"] = heroRef as CKRecordValue
        clientRecord["template"] = tplRef as CKRecordValue
        clientRecord["createdBy"] = heroRef as CKRecordValue
        clientRecord["approvalMode"] = ApprovalMode.autoApprove.rawValue as CKRecordValue
        clientRecord["active"] = true as CKRecordValue

        let serverChangedError = CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.serverRecordChanged.rawValue,
            userInfo: [CKRecordChangedErrorServerRecordKey: serverRecord]
        ))

        let resolvedRecord = await resolver.resolveFailedSave(record: clientRecord, error: serverChangedError)
        let resolved = try #require(resolvedRecord)

        // Must be capped at xpReward (50), not 70
        #expect(resolved["xpBanked"] as? Int == 50)
    }
}
