//
//  SyncEngineTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData
import Testing

// MARK: - Broken Record

private struct BrokenRecord: CloudKitRecord {
    static let recordType = "Family"

    init() {}

    init(record _: CKRecord) throws {
        // Intentionally never succeeds — only used as a seed record.
        throw CKDecodingError.missingField("BrokenRecord is not decodable")
    }

    func toRecord() -> CKRecord {
        CKRecord(recordType: Self.recordType,
                 recordID: CKRecord.ID(recordName: "broken_seed"))
    }
}

/// Thread-safe box for notification-observer state across the @Sendable closure boundary.
private final class SyncResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _receivedNotification = false
    private var _receivedErrors: [String]?

    var receivedNotification: Bool {
        get { lock.withLock { _receivedNotification } }
        set { lock.withLock { _receivedNotification = newValue } }
    }

    var receivedErrors: [String]? {
        get { lock.withLock { _receivedErrors } }
        set { lock.withLock { _receivedErrors = newValue } }
    }
}

// MARK: - Tests

@MainActor
@Suite(.serialized)
struct SyncEngineTests {
    // MARK: - Helpers

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: QuestCache.self,
            QuestTemplateCache.self,
            ProfileCache.self,
            QuestCompletionCache.self,
            FamilyCache.self,
            LedgerEntryCache.self,
            AllowancePeriodCache.self,
            AchievementCache.self,
            ProfileAchievementCache.self,
            NotificationPreferenceCache.self,
            configurations: config
        )
    }

    private func ref(_ name: String) -> CKRecord.Reference {
        CKRecord.Reference(recordID: CKRecord.ID(recordName: name), action: .none)
    }

    private func fetchAll<T: PersistentModel>(_: T.Type, in container: ModelContainer) throws -> [T] {
        try ModelContext(container).fetch(FetchDescriptor<T>())
    }

    private func remainingCount<T: PersistentModel>(_: T.Type, in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetch(FetchDescriptor<T>()).count
    }

    private struct SUT {
        let engine: SyncEngine
        let cloudKit: CloudKitService
        let cacheService: CacheService
        let coordinator: AppSyncCoordinator
        let backgroundContainer: ModelContainer
    }

    private func makeSUT(
        seedRecords: [any CloudKitRecord] = [],
        cacheContainer _: ModelContainer? = nil
    ) throws -> SUT {
        let zoneID = CKRecordZone.ID(zoneName: "SyncTestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)

        if !seedRecords.isEmpty {
            cloudKit.seedMockRecords(seedRecords)
        }

        let bgContainer = try makeContainer()
        let backgroundCache = BackgroundCacheActor(container: bgContainer)

        let cacheService = try CacheService(inMemory: true)
        let coordinator = AppSyncCoordinator()

        let engine = SyncEngine(
            cloudKit: cloudKit,
            cacheService: cacheService,
            backgroundCache: backgroundCache,
            syncCoordinator: coordinator
        )

        return SUT(engine: engine, cloudKit: cloudKit, cacheService: cacheService,
                   coordinator: coordinator, backgroundContainer: bgContainer)
    }

    // MARK: - Seed data builders

    private func seedFamily(_ name: String = "Dragons",
                            recordName: String = "fam1") -> Family
    {
        Family(name: name,
               createdBy: CKRecord.ID(recordName: "user1"),
               id: CKRecord.ID(recordName: recordName))
    }

    private func seedProfile(recordName: String = "prof1",
                             familyRef: CKRecord.Reference? = nil) -> Profile
    {
        let family = familyRef ?? ref("fam1")
        return Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "icloud1"),
            family: family,
            id: CKRecord.ID(recordName: recordName)
        )
    }

    private func seedQuest(recordName: String = "quest1",
                           familyRef: CKRecord.Reference? = nil) -> Quest
    {
        let family = familyRef ?? ref("fam1")
        return Quest(
            template: ref("tpl1"),
            assignee: ref("prof1"),
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: family,
            name: "Clean Room",
            id: CKRecord.ID(recordName: recordName)
        )
    }

    private func seedTemplate(recordName: String = "tpl1",
                              familyRef: CKRecord.Reference? = nil) -> QuestTemplate
    {
        let family = familyRef ?? ref("fam1")
        return QuestTemplate(
            name: "Clean Room",
            description: "Tidy up",
            defaultGold: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            createdBy: ref("user1"),
            family: family,
            id: CKRecord.ID(recordName: recordName)
        )
    }

    private func seedCompletion(recordName: String = "comp1",
                                familyRef: CKRecord.Reference? = nil) -> QuestCompletion
    {
        let family = familyRef ?? ref("fam1")
        return QuestCompletion(
            quest: ref("quest1"),
            completedBy: ref("prof1"),
            approvalMode: .parentVerify,
            completedDate: Date(),
            weekOf: Date(),
            family: family,
            id: CKRecord.ID(recordName: recordName)
        )
    }

    private func seedLedger(recordName: String = "ledger1",
                            familyRef: CKRecord.Reference? = nil) -> LedgerEntry
    {
        let family = familyRef ?? ref("fam1")
        return LedgerEntry(
            profile: ref("prof1"),
            amount: 5.0,
            description: "Bonus",
            family: family,
            id: CKRecord.ID(recordName: recordName)
        )
    }

    private func seedAllowance(recordName: String = "allow1",
                               familyRef: CKRecord.Reference? = nil) -> AllowancePeriod
    {
        let family = familyRef ?? ref("fam1")
        return AllowancePeriod(
            weekOf: Date(),
            profile: ref("prof1"),
            questsTotal: 5,
            family: family,
            id: CKRecord.ID(recordName: recordName)
        )
    }

    private func seedAchievement(recordName: String = "ach1",
                                 familyRef: CKRecord.Reference? = nil) -> Achievement
    {
        let family = familyRef ?? ref("fam1")
        return Achievement(
            name: "First Quest",
            description: "Complete one quest",
            iconSystemName: "star.fill",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: family,
            id: CKRecord.ID(recordName: recordName)
        )
    }

    private func seedProfileAchievement(recordName: String = "pa1",
                                        familyRef: CKRecord.Reference? = nil) -> ProfileAchievement
    {
        let family = familyRef ?? ref("fam1")
        return ProfileAchievement(
            achievement: ref("ach1"),
            profile: ref("prof1"),
            family: family,
            id: CKRecord.ID(recordName: recordName)
        )
    }

    private func seedNotificationPref(recordName: String = "notif1",
                                      familyRef: CKRecord.Reference? = nil) -> NotificationPreference
    {
        let family = familyRef ?? ref("fam1")
        return NotificationPreference(
            profile: ref("prof1"),
            eventType: .questCompleted,
            enabled: true,
            pushEnabled: true,
            family: family,
            id: CKRecord.ID(recordName: recordName)
        )
    }

    private func allTenTypes(familyRef: CKRecord.Reference? = nil) -> [any CloudKitRecord] {
        [
            seedFamily(),
            seedProfile(familyRef: familyRef),
            seedQuest(familyRef: familyRef),
            seedTemplate(familyRef: familyRef),
            seedCompletion(familyRef: familyRef),
            seedLedger(familyRef: familyRef),
            seedAllowance(familyRef: familyRef),
            seedAchievement(familyRef: familyRef),
            seedProfileAchievement(familyRef: familyRef),
            seedNotificationPref(familyRef: familyRef)
        ]
    }

    // MARK: - Tests

    // MARK: Test 1

    @Test
    func `sync all calls batch upsert for all 10 types`() async throws {
        let sut = try makeSUT(seedRecords: allTenTypes())
        await sut.engine.syncAllFamiliesUnscoped()

        #expect(try remainingCount(FamilyCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(ProfileCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(QuestCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(QuestTemplateCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(QuestCompletionCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(LedgerEntryCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(AllowancePeriodCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(AchievementCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(ProfileAchievementCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(NotificationPreferenceCache.self, in: sut.backgroundContainer) == 1)
    }

    // MARK: Test 2 — purge-missing paths

    @Test
    func `sync all calls purge missing for all 10 types`() async throws {
        let bgContainer = try makeContainer()
        let actor = BackgroundCacheActor(container: bgContainer)

        let families = [
            seedFamily("Alpha", recordName: "fam_a"),
            seedFamily("Beta", recordName: "fam_b")
        ]
        await actor.batchUpsertFamilies(families)

        let profiles = [
            seedProfile(recordName: "p_a", familyRef: ref("fam_a")),
            seedProfile(recordName: "p_b", familyRef: ref("fam_b"))
        ]
        await actor.batchUpsertProfiles(profiles)

        let quests = [
            seedQuest(recordName: "q_a", familyRef: ref("fam_a")),
            seedQuest(recordName: "q_b", familyRef: ref("fam_b"))
        ]
        await actor.batchUpsertQuests(quests)

        let templates = [
            seedTemplate(recordName: "t_a", familyRef: ref("fam_a")),
            seedTemplate(recordName: "t_b", familyRef: ref("fam_b"))
        ]
        await actor.batchUpsertQuestTemplates(templates)

        let completions = [
            seedCompletion(recordName: "c_a", familyRef: ref("fam_a")),
            seedCompletion(recordName: "c_b", familyRef: ref("fam_b"))
        ]
        await actor.batchUpsertQuestCompletions(completions)

        let ledgers = [
            seedLedger(recordName: "l_a", familyRef: ref("fam_a")),
            seedLedger(recordName: "l_b", familyRef: ref("fam_b"))
        ]
        await actor.batchUpsertLedgerEntries(ledgers)

        let allowances = [
            seedAllowance(recordName: "ap_a", familyRef: ref("fam_a")),
            seedAllowance(recordName: "ap_b", familyRef: ref("fam_b"))
        ]
        await actor.batchUpsertAllowancePeriods(allowances)

        let achievements = [
            seedAchievement(recordName: "ach_a", familyRef: ref("fam_a")),
            seedAchievement(recordName: "ach_b", familyRef: ref("fam_b"))
        ]
        await actor.batchUpsertAchievements(achievements)

        let profileAchs = [
            seedProfileAchievement(recordName: "pa_a", familyRef: ref("fam_a")),
            seedProfileAchievement(recordName: "pa_b", familyRef: ref("fam_b"))
        ]
        await actor.batchUpsertProfileAchievements(profileAchs)

        let notifPrefs = [
            seedNotificationPref(recordName: "n_a", familyRef: ref("fam_a")),
            seedNotificationPref(recordName: "n_b", familyRef: ref("fam_b"))
        ]
        await actor.batchUpsertNotificationPreferences(notifPrefs)

        #expect(try remainingCount(FamilyCache.self, in: bgContainer) == 2)
        #expect(try remainingCount(NotificationPreferenceCache.self, in: bgContainer) == 2)

        let zoneID = CKRecordZone.ID(zoneName: "SyncTestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        cloudKit.seedMockRecords(allTenTypes(familyRef: ref("fam_a")))

        let cacheService = try CacheService(inMemory: true)
        let coordinator = AppSyncCoordinator()
        let engine = SyncEngine(
            cloudKit: cloudKit,
            cacheService: cacheService,
            backgroundCache: actor,
            syncCoordinator: coordinator
        )

        await engine.syncAllFamiliesUnscoped()

        #expect(try remainingCount(FamilyCache.self, in: bgContainer) == 1)
        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 1)
        #expect(try remainingCount(QuestCache.self, in: bgContainer) == 1)
        #expect(try remainingCount(QuestTemplateCache.self, in: bgContainer) == 1)
        #expect(try remainingCount(QuestCompletionCache.self, in: bgContainer) == 1)
        #expect(try remainingCount(LedgerEntryCache.self, in: bgContainer) == 1)
        #expect(try remainingCount(AllowancePeriodCache.self, in: bgContainer) == 1)
        #expect(try remainingCount(AchievementCache.self, in: bgContainer) == 1)
        #expect(try remainingCount(ProfileAchievementCache.self, in: bgContainer) == 1)
        #expect(try remainingCount(NotificationPreferenceCache.self, in: bgContainer) == 1)
    }

    // MARK: Test 3 — families get purged

    @Test
    func `sync all purges families`() async throws {
        let bgContainer = try makeContainer()
        let actor = BackgroundCacheActor(container: bgContainer)

        await actor.batchUpsertFamilies([
            seedFamily("Alpha", recordName: "fam_a"),
            seedFamily("Beta", recordName: "fam_b")
        ])
        #expect(try remainingCount(FamilyCache.self, in: bgContainer) == 2)

        let zoneID = CKRecordZone.ID(zoneName: "SyncTestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        cloudKit.seedMockRecords([seedFamily("Alpha", recordName: "fam_a")])

        let cacheService = try CacheService(inMemory: true)
        let coordinator = AppSyncCoordinator()
        let engine = SyncEngine(
            cloudKit: cloudKit,
            cacheService: cacheService,
            backgroundCache: actor,
            syncCoordinator: coordinator
        )

        await engine.syncAllFamiliesUnscoped()

        #expect(try remainingCount(FamilyCache.self, in: bgContainer) == 1)
        let remaining = try fetchAll(FamilyCache.self, in: bgContainer)
        #expect(remaining.first?.recordName == "fam_a")
    }

    // MARK: Test 4 — notification preferences purged

    @Test
    func `sync all purges notification preferences`() async throws {
        let bgContainer = try makeContainer()
        let actor = BackgroundCacheActor(container: bgContainer)

        await actor.batchUpsertNotificationPreferences([
            seedNotificationPref(recordName: "np_a", familyRef: ref("fam_a")),
            seedNotificationPref(recordName: "np_b", familyRef: ref("fam_b"))
        ])
        #expect(try remainingCount(NotificationPreferenceCache.self, in: bgContainer) == 2)

        let zoneID = CKRecordZone.ID(zoneName: "SyncTestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        cloudKit.seedMockRecords([
            seedNotificationPref(recordName: "np_a", familyRef: ref("fam_a"))
        ])

        let cacheService = try CacheService(inMemory: true)
        let coordinator = AppSyncCoordinator()
        let engine = SyncEngine(
            cloudKit: cloudKit,
            cacheService: cacheService,
            backgroundCache: actor,
            syncCoordinator: coordinator
        )

        await engine.syncAllFamiliesUnscoped()

        #expect(try remainingCount(NotificationPreferenceCache.self, in: bgContainer) == 1)
        let remaining = try fetchAll(NotificationPreferenceCache.self, in: bgContainer)
        #expect(remaining.first?.recordName == "np_a")
    }

    // MARK: Test 5

    @Test
    func `sync all handles empty zone`() async throws {
        let sut = try makeSUT(seedRecords: [])

        await sut.engine.syncAllFamiliesUnscoped()

        #expect(try remainingCount(FamilyCache.self, in: sut.backgroundContainer) == 0)
        #expect(try remainingCount(ProfileCache.self, in: sut.backgroundContainer) == 0)
        #expect(try remainingCount(QuestCache.self, in: sut.backgroundContainer) == 0)
        #expect(try remainingCount(NotificationPreferenceCache.self, in: sut.backgroundContainer) == 0)
    }

    // MARK: Test 6

    @Test
    func `incremental sync persists token after completion`() async throws {
        let sut = try makeSUT(seedRecords: allTenTypes())

        let zoneID = sut.cloudKit.resolvedZoneID
        let dbLabel = sut.cloudKit.activeIsOwner ? "private" : "shared"
        let tokenKey = "ck_change_token.\(zoneID.zoneName).\(dbLabel)"
        UserDefaults.standard.removeObject(forKey: tokenKey)

        await sut.engine.incrementalSync()

        #expect(try remainingCount(FamilyCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(ProfileCache.self, in: sut.backgroundContainer) == 1)

        #expect(sut.engine.lastSyncedAt != nil)
    }

    // MARK: Test 7 — N1 regression: incrementalSync propagates familyRecordName

    @Test
    func `incremental sync passes family record name to sync all fallback`() async throws {
        let bgContainer = try makeContainer()
        let actor = BackgroundCacheActor(container: bgContainer)

        await actor.batchUpsertProfiles([
            seedProfile(recordName: "p_a", familyRef: ref("fam_a")),
            seedProfile(recordName: "p_b", familyRef: ref("fam_b"))
        ])
        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 2)

        let zoneID = CKRecordZone.ID(zoneName: "SyncTestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        cloudKit.seedMockRecords([seedProfile(recordName: "p_a", familyRef: ref("fam_a"))])

        let cacheService = try CacheService(inMemory: true)
        let coordinator = AppSyncCoordinator()
        let engine = SyncEngine(
            cloudKit: cloudKit,
            cacheService: cacheService,
            backgroundCache: actor,
            syncCoordinator: coordinator
        )

        let dbLabel = cloudKit.activeIsOwner ? "private" : "shared"
        let tokenKey = "ck_change_token.\(zoneID.zoneName).\(dbLabel)"
        UserDefaults.standard.removeObject(forKey: tokenKey)

        await engine.incrementalSync(familyRecordName: "fam_a")

        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 2)

        let remaining = try fetchAll(ProfileCache.self, in: bgContainer)
        let recordNames = Set(remaining.map(\.recordName))
        #expect(recordNames.contains("p_a"))
        #expect(recordNames.contains("p_b"))

        #expect(engine.lastSyncedAt != nil)
    }

    // MARK: Test 8 — concurrency

    @Test
    func `incremental sync handles more coming recursively`() async throws {
        let sut = try makeSUT(seedRecords: allTenTypes())

        async let first = sut.engine.syncAllFamiliesUnscoped()
        async let second = sut.engine.syncAllFamiliesUnscoped()
        await first
        await second

        try await Task.sleep(for: .milliseconds(500))

        #expect(sut.engine.isSyncing == false)
        #expect(sut.engine.lastSyncedAt != nil)
    }

    // MARK: Test 9 — clean sync notification

    @Test
    func `sync did complete posts notification on success`() async throws {
        let sut = try makeSUT(seedRecords: allTenTypes())

        let box = SyncResultBox()

        let observer = NotificationCenter.default.addObserver(
            forName: .syncDidComplete,
            object: sut.engine,
            queue: .main
        ) { notification in
            box.receivedNotification = true
            box.receivedErrors = notification.userInfo?["errors"] as? [String]
        }

        await sut.engine.syncAllFamiliesUnscoped()

        await Task.yield()

        #expect(box.receivedNotification == true)
        #expect(box.receivedErrors == nil)

        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: Test 10 — M1 regression: notification carries errors

    @Test
    func `sync did complete posts notification on partial failure`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "SyncTestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)

        cloudKit.seedMockRecords([
            BrokenRecord(),
            seedProfile(),
            seedQuest(),
            seedTemplate(),
            seedCompletion(),
            seedLedger(),
            seedAllowance(),
            seedAchievement(),
            seedProfileAchievement(),
            seedNotificationPref()
        ])

        let bgContainer = try makeContainer()
        let backgroundCache = BackgroundCacheActor(container: bgContainer)
        let cacheService = try CacheService(inMemory: true)
        let coordinator = AppSyncCoordinator()

        let engine = SyncEngine(
            cloudKit: cloudKit,
            cacheService: cacheService,
            backgroundCache: backgroundCache,
            syncCoordinator: coordinator
        )

        let box = SyncResultBox()

        let observer = NotificationCenter.default.addObserver(
            forName: .syncDidComplete,
            object: engine,
            queue: .main
        ) { notification in
            box.receivedNotification = true
            box.receivedErrors = notification.userInfo?["errors"] as? [String]
        }

        await engine.syncAllFamiliesUnscoped()
        await Task.yield()

        #expect(box.receivedNotification == true)
        #expect(box.receivedErrors != nil)
        #expect(box.receivedErrors?.isEmpty == false)

        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: Test 11 — M2 regression: clearAll before resync

    @Test
    func `zone reset purges before resync`() async throws {
        let sut = try makeSUT(seedRecords: allTenTypes())

        let staleCtx = ModelContext(sut.cacheService.container)
        staleCtx.insert(FamilyCache(
            recordName: "stale_family",
            name: "Stale Guild",
            createdByRecordName: "stale_user",
            createdAt: Date.distantPast,
            payoutPolicy: "perQuest"
        ))
        try staleCtx.save()

        #expect(try remainingCount(FamilyCache.self, in: sut.cacheService.container) == 1)
        #expect(try remainingCount(FamilyCache.self, in: sut.backgroundContainer) == 0)

        let box = SyncResultBox()
        let observer = NotificationCenter.default.addObserver(
            forName: .syncDidComplete,
            object: sut.engine,
            queue: .main
        ) { _ in
            box.receivedNotification = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        sut.coordinator.notifyZoneReset()

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !box.receivedNotification, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(box.receivedNotification == true)

        #expect(try remainingCount(FamilyCache.self, in: sut.cacheService.container) == 0)
        #expect(try remainingCount(FamilyCache.self, in: sut.backgroundContainer) == 1)
        #expect(sut.engine.lastSyncedAt != nil)
    }

    // MARK: Test 12 — tokenKey scopes per database

    @Test
    func `tokenKey scopes correctly for shared vs private databases`() throws {
        let sut = try makeSUT(seedRecords: [])

        let zoneID = CKRecordZone.ID(zoneName: "FamilyZone", ownerName: "TestOwner")

        let privateKey = sut.engine.tokenKey(for: zoneID, db: sut.cloudKit.privateDatabase)
        let sharedKey = sut.engine.tokenKey(for: zoneID, db: sut.cloudKit.sharedDatabase)

        #expect(privateKey.contains("FamilyZone"))
        #expect(sharedKey.contains("FamilyZone"))

        #expect(privateKey != sharedKey)
        #expect(privateKey.hasSuffix(".private"))
        #expect(sharedKey.hasSuffix(".shared"))
    }

    // MARK: Test 13 — F015: recordChanged handler is family-scoped

    @Test
    func `push handler recordChanged syncs only active family`() async throws {
        let bgContainer = try makeContainer()
        let actor = BackgroundCacheActor(container: bgContainer)

        await actor.batchUpsertProfiles([
            seedProfile(recordName: "p_a", familyRef: ref("fam_a")),
            seedProfile(recordName: "p_b", familyRef: ref("fam_b"))
        ])
        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 2)

        let zoneID = CKRecordZone.ID(zoneName: "fam_a", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.seedMockRecords([seedProfile(recordName: "p_a", familyRef: ref("fam_a"))])

        let dbLabel = cloudKit.activeIsOwner ? "private" : "shared"
        let tokenKey = "ck_change_token.\(zoneID.zoneName).\(dbLabel)"
        UserDefaults.standard.removeObject(forKey: tokenKey)

        let cacheService = try CacheService(inMemory: true)
        let coordinator = AppSyncCoordinator()
        let engine = SyncEngine(
            cloudKit: cloudKit,
            cacheService: cacheService,
            backgroundCache: actor,
            syncCoordinator: coordinator
        )

        let box = SyncResultBox()
        let observer = NotificationCenter.default.addObserver(
            forName: .syncDidComplete,
            object: engine,
            queue: .main
        ) { _ in box.receivedNotification = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        coordinator.handleDatabaseChange(subscriptionID: "test-sub-fam-a")

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !box.receivedNotification, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(box.receivedNotification == true)

        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 2)
        let remaining = try fetchAll(ProfileCache.self, in: bgContainer)
        let recordNames = Set(remaining.map(\.recordName))
        #expect(recordNames.contains("p_a"))
        #expect(recordNames.contains("p_b"))
    }

    // MARK: Test 14 — F015: shareAccepted handler is family-scoped

    @Test
    func `push handler shareAccepted syncs only accepted family`() async throws {
        let bgContainer = try makeContainer()
        let actor = BackgroundCacheActor(container: bgContainer)

        await actor.batchUpsertProfiles([
            seedProfile(recordName: "p_a", familyRef: ref("fam_a")),
            seedProfile(recordName: "p_b", familyRef: ref("fam_b"))
        ])
        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 2)

        let zoneID = CKRecordZone.ID(zoneName: "fam_a", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        cloudKit.seedMockRecords([seedProfile(recordName: "p_a", familyRef: ref("fam_a"))])

        cloudKit.activeFamilyZoneID = CKRecordZone.ID(zoneName: "fam_b", ownerName: "StaleOwner")

        let tokenKey = "ck_change_token.fam_a.shared"
        UserDefaults.standard.removeObject(forKey: tokenKey)

        let shareZoneID = CKRecordZone.ID(zoneName: "fam_a", ownerName: "ShareOwner")
        let shareRecordID = CKRecord.ID(recordName: "share-root", zoneID: shareZoneID)

        let cacheService = try CacheService(inMemory: true)
        let coordinator = AppSyncCoordinator()
        let engine = SyncEngine(
            cloudKit: cloudKit,
            cacheService: cacheService,
            backgroundCache: actor,
            syncCoordinator: coordinator
        )

        let box = SyncResultBox()
        let observer = NotificationCenter.default.addObserver(
            forName: .syncDidComplete,
            object: engine,
            queue: .main
        ) { _ in box.receivedNotification = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        coordinator.notifyShareAccepted(shareID: shareRecordID)

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !box.receivedNotification, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(box.receivedNotification == true)

        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 2)
        let remaining = try fetchAll(ProfileCache.self, in: bgContainer)
        let remainingNames = Set(remaining.map(\.recordName))
        #expect(remainingNames.contains("p_a"))
        #expect(remainingNames.contains("p_b"))
    }

    // MARK: Test 15 — F015: zoneReset handler is family-scoped

    @Test
    func `push handler zoneReset syncs only resolved family`() async throws {
        let bgContainer = try makeContainer()
        let actor = BackgroundCacheActor(container: bgContainer)

        await actor.batchUpsertProfiles([
            seedProfile(recordName: "p_a", familyRef: ref("fam_a")),
            seedProfile(recordName: "p_b", familyRef: ref("fam_b"))
        ])
        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 2)

        let zoneID = CKRecordZone.ID(zoneName: "fam_a", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.seedMockRecords([seedProfile(recordName: "p_a", familyRef: ref("fam_a"))])

        let dbType = cloudKit.activeIsOwner ? "private" : "shared"
        let tokenKey = "ck_change_token.\(zoneID.zoneName).\(dbType)"
        UserDefaults.standard.removeObject(forKey: tokenKey)

        let cacheService = try CacheService(inMemory: true)
        let coordinator = AppSyncCoordinator()
        let engine = SyncEngine(
            cloudKit: cloudKit,
            cacheService: cacheService,
            backgroundCache: actor,
            syncCoordinator: coordinator
        )

        let box = SyncResultBox()
        let observer = NotificationCenter.default.addObserver(
            forName: .syncDidComplete,
            object: engine,
            queue: .main
        ) { _ in box.receivedNotification = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        coordinator.notifyZoneReset()

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !box.receivedNotification, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(box.receivedNotification == true)

        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 2)
        let remaining = try fetchAll(ProfileCache.self, in: bgContainer)
        let remainingNames = Set(remaining.map(\.recordName))
        #expect(remainingNames.contains("p_a"))
        #expect(remainingNames.contains("p_b"))
    }
}
