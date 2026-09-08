//
//  ManualSpendingServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/1/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct SpendingServiceTests {
    // MARK: - Mock Infrastructure

    private enum MockError: Error, Equatable {
        case saveFailed
    }

    private final class FailingCloudKitService: MockCloudKitService {
        override init(zoneID: CKRecordZone.ID? = nil) {
            super.init()
            self.activeFamilyZoneID = zoneID
        }

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
            creatorUserRecordName: "parent1",
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
    }

    private func setupActiveScope(
        appState: AppState,
        cloudKit: MockCloudKitService,
        family: Family,
        actingProfile: Profile? = nil
    ) {
        appState.family = family
        appState.familyZoneID = family.id.zoneID
        appState.isZoneOwner = true
        cloudKit.activeFamilyZoneID = family.id.zoneID
        cloudKit.activeIsOwner = true
        if let actingProfile {
            appState.currentProfile = actingProfile
        }
    }

    // MARK: - Tests

    @Test
    func `manual spending service logManual writes immediately to local cache`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = SpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: hero)

        let entry = try await service.logManual(profile: hero, family: family, familyRecordName: family.id.recordName, description: "Test Buy", amount: 1000)
        #expect(entry.amount == -1000)

        let cached = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        #expect(!cached.isEmpty, "LedgerEntry must be written to cache immediately")
        #expect(cached.first?.amount == -1000)
    }

    @Test
    func `manual spending service delete deletes immediately from cache`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = SpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)
        let familyRef = makeFamilyRef(zoneID)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: hero)

        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            amount: -1500,
            description: "Existing item",
            date: Date(),
            source: "manual",
            family: familyRef,
            id: CKRecord.ID(recordName: "manual-test-existing", zoneID: zoneID)
        )
        await cache.upsertLedgerEntry(entry)
        #expect(!cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName).isEmpty)

        try await service.delete(entry)

        let cached = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        #expect(cached.isEmpty, "LedgerEntry must be deleted from cache immediately")
    }

    // MARK: - Identity guards

    private func makeParent(_ zoneID: CKRecordZone.ID) -> Profile {
        let userID = CKRecord.ID(recordName: "parent1", zoneID: zoneID)
        return Profile(
            displayName: "Parent GM",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: userID,
            family: makeFamilyRef(zoneID),
            id: userID
        )
    }

    @Test
    func `logManual throws unauthorized when actor is not target profile`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = SpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let actor = makeHero(zoneID)
        let victimID = CKRecord.ID(recordName: "hero2", zoneID: zoneID)
        let victim = Profile(
            displayName: "Victim Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: victimID,
            family: makeFamilyRef(zoneID),
            id: victimID
        )
        let family = makeFamily(zoneID)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: actor)

        do {
            _ = try await service.logManual(
                profile: victim,
                family: family,
                familyRecordName: family.id.recordName,
                description: "Should not save",
                amount: 1000
            )
            #expect(Bool(false), "Expected logManual to throw unauthorized")
        } catch {
            #expect(error as? FamilyServiceError == .unauthorized)
        }

        let cached = cache.fetchLedgerEntries(profileRecordName: victim.id.recordName, family: family.id.recordName)
        #expect(cached.isEmpty, "logManual must not write when the actor is not the target profile")
    }

    @Test
    func `delete throws unauthorized when actor is neither entry owner nor parent`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = SpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let actor = makeHero(zoneID)
        let family = makeFamily(zoneID)
        let otherHeroID = CKRecord.ID(recordName: "hero2", zoneID: zoneID)
        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: otherHeroID, action: .none),
            amount: -1000,
            description: "Another hero's entry",
            date: Date(),
            source: "manual",
            family: makeFamilyRef(zoneID),
            id: CKRecord.ID(recordName: "manual-test-other-hero", zoneID: zoneID)
        )
        await cache.upsertLedgerEntry(entry)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: actor)

        do {
            try await service.delete(entry)
            #expect(Bool(false), "Expected delete to throw unauthorized")
        } catch {
            #expect(error as? FamilyServiceError == .unauthorized)
        }

        // The entry must remain in cache — the unauthorized delete must not invalidate it.
        let cached = cache.fetchLedgerEntries(profileRecordName: otherHeroID.recordName, family: family.id.recordName)
        #expect(cached.first?.amount == -1000, "unauthorized delete must not touch the entry")
    }

    @Test
    func `delete succeeds when actor is the entry owner`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = SpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)
        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            amount: -1000,
            description: "Hero's own entry",
            date: Date(),
            source: "manual",
            family: makeFamilyRef(zoneID),
            id: CKRecord.ID(recordName: "manual-test-own-entry", zoneID: zoneID)
        )
        await cache.upsertLedgerEntry(entry)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: hero)

        try await service.delete(entry)

        let cached = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        #expect(cached.isEmpty, "self-owned entry should be deleted")
    }

    @Test
    func `delete succeeds when actor is a parent`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = SpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let parent = makeParent(zoneID)
        let family = makeFamily(zoneID)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: heroID, action: .none),
            amount: -1000,
            description: "Hero's entry under parent oversight",
            date: Date(),
            source: "manual",
            family: makeFamilyRef(zoneID),
            id: CKRecord.ID(recordName: "manual-test-parent-delete", zoneID: zoneID)
        )
        await cache.upsertLedgerEntry(entry)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: parent)

        try await service.delete(entry)

        let cached = cache.fetchLedgerEntries(profileRecordName: heroID.recordName, family: family.id.recordName)
        #expect(cached.isEmpty, "parent should be able to delete a hero's ledger entry")
    }

    @Test
    func `delete throws unsupported when entry source is quest`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = SpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)
        let questEntry = LedgerEntry(
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            amount: 5000,
            description: "Quest earnings",
            date: Date(),
            source: "quest",
            family: makeFamilyRef(zoneID),
            id: CKRecord.ID(recordName: "rt-period1", zoneID: zoneID)
        )
        await cache.upsertLedgerEntry(questEntry)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: hero)

        do {
            try await service.delete(questEntry)
            #expect(Bool(false), "Expected delete of quest-source entry to throw unsupported")
        } catch {
            #expect(error as? SpendingServiceError == .unsupported)
        }

        let cached = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        #expect(cached.first?.amount == 5000, "quest entry must not be deleted")
    }

    // MARK: - Snapshot fetch family scoping

    @Test
    func `logManual scopes optimistic snapshot fetch to active familyRecordName`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = SpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let familyA = Family(
            name: "Family A",
            creatorUserRecordName: "parentA",
            id: CKRecord.ID(recordName: "famA", zoneID: zoneID)
        )
        let familyB = Family(
            name: "Family B",
            creatorUserRecordName: "parentB",
            id: CKRecord.ID(recordName: "famB", zoneID: zoneID)
        )
        await cache.upsertFamily(familyA)
        await cache.upsertFamily(familyB)

        let heroRefA = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let familyRefA = CKRecord.Reference(recordID: familyA.id, action: .none)
        let hero = Profile(
            displayName: "Hero A",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: heroRefA,
            family: familyRefA,
            id: heroRefA
        )
        await cache.upsertProfile(hero)

        let legacyFamilyB = LedgerEntryCache(
            recordName: "legacy_famB_entry",
            profileRecordName: hero.id.recordName,
            familyRecordName: familyB.id.recordName,
            amount: -750,
            entryDescription: "Spent in the old family",
            date: Date().addingTimeInterval(-3600),
            source: "manual",
            changeTag: "v1"
        )
        await cache.upsertLedgerEntry(legacyFamilyB.toLedgerEntry(zoneID: zoneID))

        setupActiveScope(appState: appState, cloudKit: cloudKit, family: familyA, actingProfile: hero)
        cache.ledgerEntryFetchScopes = []

        _ = try await service.logManual(
            profile: hero,
            family: familyA,
            familyRecordName: familyA.id.recordName,
            description: "New sword",
            amount: 1200
        )

        let familyARows = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: familyA.id.recordName)
        #expect(familyARows.count == 1, "manual entry must persist in familyA")

        let familyBRows = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: familyB.id.recordName)
        #expect(familyBRows.count == 1, "logManual must not touch the other family's cache slice")
        #expect(familyBRows.first?.recordName == "legacy_famB_entry")
        #expect(familyBRows.first?.changeTag == "v1")
    }

    @Test
    func `deposit creates positive ledger entry with source deposit`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = SpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let parent = makeParent(zoneID)
        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: parent)

        let entries = try await service.depositEntries(
            profile: hero,
            family: family,
            familyRecordName: family.id.recordName,
            description: "Birthday gift from Grandpa",
            amount: 2500
        )
        let entry = try #require(entries.first)

        #expect(entries.count == 1)
        #expect(entry.amount == 2500)
        #expect(entry.source == "deposit")
        #expect(entry.description == "Birthday gift from Grandpa")

        let cached = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        #expect(cached.count == 1)
        #expect(cached.first?.amount == 2500)
        #expect(cached.first?.source == "deposit")
    }

    @Test
    func `withdraw creates negative ledger entry with source withdrawal`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = SpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let parent = makeParent(zoneID)
        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: parent)

        let entry = try await service.withdraw(
            profile: hero,
            family: family,
            familyRecordName: family.id.recordName,
            description: "Camp cash",
            amount: 1000
        )

        #expect(entry.amount == -1000)
        #expect(entry.source == "withdrawal")
        #expect(entry.description == "Camp cash")

        let cached = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        #expect(cached.count == 1)
        #expect(cached.first?.amount == -1000)
        #expect(cached.first?.source == "withdrawal")
    }

    @Test
    func `logManual persists location to CloudKit and SwiftData cache`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = SpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: hero)

        let entry = try await service.logManual(
            profile: hero,
            family: family,
            familyRecordName: family.id.recordName,
            description: "Board game",
            amount: 1500,
            location: "Hobby Lobby"
        )

        #expect(entry.location == "Hobby Lobby")
        let cached = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        #expect(cached.count == 1)
        #expect(cached.first?.location == "Hobby Lobby")
    }

    @Test
    func `spending service error underlying does not leak raw string`() {
        let raw = "<CKErrorDomain: 20> \"serverRejectedRequest\"; _zoneID=PrivateZone"
        let error = SpendingServiceError.underlying(raw)
        let description = error.errorDescription
        #expect(description == "Something went wrong. Please try again.")
        #expect(!(description ?? "").contains(raw))
        #expect(!(description ?? "").contains("CKErrorDomain"))
    }

    @Test
    func `app state error cache initialization failed does not leak raw string`() {
        let raw = "SwiftData.SwiftDataError(_error: SwiftData.SwiftDataError.loadIssueModelContainer)"
        let error = AppState.AppStateError.cacheInitializationFailed(raw)
        let description = error.errorDescription
        #expect(description == "Failed to initialize the local cache. Please try relaunching the app.")
        #expect(!(description ?? "").contains(raw))
        #expect(!(description ?? "").contains("SwiftDataError"))
    }

    // MARK: - Bucket attribution

    /// Bucket reads need a fully wired service because transfer paths guard on
    /// every dependency; engines stay inert under the unit-test gate.
    private func makeBucketService(
        cache: CacheService,
        appState: AppState,
        cloudKit: MockCloudKitService
    ) -> BucketService {
        let conflictResolver = CKSyncConflictResolver(cacheService: cache, appState: appState)
        let delegateHandler = CKSyncEngineDelegateHandler(
            conflictResolver: conflictResolver,
            cacheService: cache,
            appState: appState
        )
        let syncCoordinator = CKSyncEngineCoordinator(
            cloudKitService: cloudKit,
            delegateHandler: delegateHandler,
            appState: appState,
            defaults: UserDefaults.ephemeral()
        )
        return BucketService(cacheService: cache, syncCoordinator: syncCoordinator, appState: appState)
    }

    private func seedAttributedEntry(
        _ cache: CacheService,
        recordName: String,
        amount: Int64,
        source: String,
        bucketKind: String?,
        profileID: CKRecord.ID,
        familyRef: CKRecord.Reference,
        zoneID: CKRecordZone.ID
    ) {
        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: profileID, action: .none),
            amount: amount,
            description: recordName,
            date: Date(),
            source: source,
            bucketKind: bucketKind,
            family: familyRef,
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
        cache.context?.insert(LedgerEntryCache(from: entry))
        _ = cache.saveContext()
    }

    @Test
    func `manual purchase reduces the wallet without touching savings buckets`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = SpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: hero)

        // Prior week's split payout history: 12.00 / 5.00 / 3.00.
        seedAttributedEntry(cache, recordName: "seed-spend", amount: 1200, source: "quest",
                            bucketKind: BucketKind.spend.rawValue, profileID: hero.id,
                            familyRef: makeFamilyRef(zoneID), zoneID: zoneID)
        seedAttributedEntry(cache, recordName: "seed-short", amount: 500, source: "quest",
                            bucketKind: BucketKind.shortTermSave.rawValue, profileID: hero.id,
                            familyRef: makeFamilyRef(zoneID), zoneID: zoneID)
        seedAttributedEntry(cache, recordName: "seed-long", amount: 300, source: "quest",
                            bucketKind: BucketKind.longTermSave.rawValue, profileID: hero.id,
                            familyRef: makeFamilyRef(zoneID), zoneID: zoneID)

        let buckets = makeBucketService(cache: cache, appState: appState, cloudKit: cloudKit)

        let entry = try await service.logManual(
            profile: hero,
            family: family,
            familyRecordName: family.id.recordName,
            description: "Comic book",
            amount: 600
        )
        #expect(entry.amount == -600)
        #expect(entry.source == "manual")
        #expect(entry.bucketKind == BucketKind.spend.rawValue)

        // Savings allocations are never silently drained by a purchase; the
        // spend-attributed purchase draws down only the spend bucket.
        let balances = buckets.bucketBalances(
            profileRecordName: hero.id.recordName,
            familyRecordName: family.id.recordName
        )
        #expect(balances[.spend] == 600)
        #expect(balances[.shortTermSave] == 500)
        #expect(balances[.longTermSave] == 300)

        let walletTotal = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
            .reduce(Int64(0)) { $0 + $1.amount }
        #expect(walletTotal == 1400)
    }

    @Test
    func `spend-attributed purchase draws down the spend bucket alone`() throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let buckets = makeBucketService(cache: cache, appState: appState, cloudKit: cloudKit)

        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)

        seedAttributedEntry(cache, recordName: "seed-spend", amount: 1000, source: "quest",
                            bucketKind: BucketKind.spend.rawValue, profileID: hero.id,
                            familyRef: makeFamilyRef(zoneID), zoneID: zoneID)
        seedAttributedEntry(cache, recordName: "seed-short", amount: 400, source: "quest",
                            bucketKind: BucketKind.shortTermSave.rawValue, profileID: hero.id,
                            familyRef: makeFamilyRef(zoneID), zoneID: zoneID)
        // A purchase recorded against the Spend bucket leaves the save buckets intact.
        seedAttributedEntry(cache, recordName: "purchase-spend", amount: -600, source: "manual",
                            bucketKind: BucketKind.spend.rawValue, profileID: hero.id,
                            familyRef: makeFamilyRef(zoneID), zoneID: zoneID)

        let balances = buckets.bucketBalances(
            profileRecordName: hero.id.recordName,
            familyRecordName: family.id.recordName
        )
        #expect(balances[.spend] == 400)
        #expect(balances[.shortTermSave] == 400)
        #expect(balances[.longTermSave] == nil)
        #expect(balances.count == 2)
    }

    // MARK: - Deterministic ID dedupe (cross-device)

    @Test
    func `same inputs produce same recordName across two devices`() async throws {
        let zoneID = makeZoneID()
        let family = makeFamily(zoneID)
        let hero = makeHero(zoneID)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let description = "Deterministic Coffee"
        let amount: Int64 = 450
        let location = "Cafe"

        // WHY: CloudKit dedupes by recordName — identical payloads must converge
        // to the same deterministic ID on every device, never a random UUID.
        func makeService() throws -> SpendingService {
            let ck = MockCloudKitService()
            ck.activeFamilyZoneID = zoneID
            let cache = try CacheService(inMemory: true)
            let appState = AppState()
            let service = SpendingService(cloudKit: ck, cacheService: cache, appState: appState)
            setupActiveScope(appState: appState, cloudKit: ck, family: family, actingProfile: hero)
            return service
        }

        let serviceA = try makeService()
        let entryA = try await serviceA.logManual(
            profile: hero, family: family, familyRecordName: family.id.recordName,
            description: description, amount: amount, location: location, date: fixedDate
        )

        let serviceB = try makeService()
        let entryB = try await serviceB.logManual(
            profile: hero, family: family, familyRecordName: family.id.recordName,
            description: description, amount: amount, location: location, date: fixedDate
        )

        #expect(entryA.id.recordName == entryB.id.recordName, "Same inputs must yield same deterministic recordName across devices")
        // Must not contain UUID randomness — deterministic suffix is hex + ms only.
        #expect(!entryA.id.recordName.contains("-UUID") && entryA.id.recordName.count < 120)
    }

    @Test
    func `different payloads produce different deterministic names without UUID collision`() async throws {
        let zoneID = makeZoneID()
        let family = makeFamily(zoneID)
        let hero = makeHero(zoneID)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let baseDescription = "Deterministic Lunch"
        let amount: Int64 = 999

        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = SpendingService(cloudKit: ck, cacheService: cache, appState: appState)
        setupActiveScope(appState: appState, cloudKit: ck, family: family, actingProfile: hero)

        // Seed a base entry.
        let baseEntry = try await service.logManual(
            profile: hero, family: family, familyRecordName: family.id.recordName,
            description: baseDescription, amount: amount, location: "Cafe A", date: fixedDate
        )
        let baseName = baseEntry.id.recordName

        /// Same deterministic base would collide, but different location must
        /// produce a distinct deterministic extended name, not a UUID.
        /// Manually seed a colliding base name with different payload to force
        /// the deterministic extended path. We simulate the collision by
        /// inserting a row whose recordName equals the base that the next
        /// call will compute, but with differing location.
        func divergentRecordName(location: String) async throws -> String {
            let ck2 = MockCloudKitService()
            ck2.activeFamilyZoneID = zoneID
            let cache2 = try CacheService(inMemory: true)
            // Pre-seed cache2 with the base entry to force collision on next write.
            let baseLedger = LedgerEntry(
                profile: CKRecord.Reference(recordID: hero.id, action: .none),
                amount: -abs(amount),
                description: baseDescription,
                location: "Cafe A",
                date: fixedDate,
                source: "manual",
                family: makeFamilyRef(zoneID),
                id: CKRecord.ID(recordName: baseName, zoneID: zoneID)
            )
            await cache2.upsertLedgerEntry(baseLedger)
            let appState2 = AppState()
            let svc2 = SpendingService(cloudKit: ck2, cacheService: cache2, appState: appState2)
            setupActiveScope(appState: appState2, cloudKit: ck2, family: family, actingProfile: hero)
            let entry = try await svc2.logManual(
                profile: hero, family: family, familyRecordName: family.id.recordName,
                description: baseDescription, amount: amount, location: location, date: fixedDate
            )
            return entry.id.recordName
        }

        let name1 = try await divergentRecordName(location: "Cafe B")
        let name2 = try await divergentRecordName(location: "Cafe B")

        #expect(name1 == name2, "Different payload divergent ID must be deterministic across devices")
        #expect(name1 != baseName, "Divergent payload must not collide with base recordName")
        #expect(!name1.lowercased().contains("uuid"), "Extended ID must not contain random UUID")
        // Extended deterministic suffix format: base-hex(8)-msSuffix
        #expect(name1.hasPrefix(baseName + "-"), "Extended ID must extend base with deterministic suffix")
        let suffix = String(name1.dropFirst(baseName.count + 1))
        let parts = suffix.split(separator: "-")
        #expect(parts.count == 2, "Suffix must be hex(8)-msSuffix")
        #expect(parts[0].count == 8 && parts[0].allSatisfy(\.isHexDigit), "First suffix part must be 4-byte hex")
    }

    @Test
    func `double run with same inputs is idempotent — no duplicate row`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = SpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: hero)

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await service.logManual(
            profile: hero, family: family, familyRecordName: family.id.recordName,
            description: "Idempotent Latte", amount: 500, location: "Cafe", date: fixedDate
        )
        let second = try await service.logManual(
            profile: hero, family: family, familyRecordName: family.id.recordName,
            description: "Idempotent Latte", amount: 500, location: "Cafe", date: fixedDate
        )

        #expect(first.id.recordName == second.id.recordName, "Idempotent double-run must converge to same recordName")
        let cached = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        #expect(cached.count == 1, "Double-run must not create duplicate ledger row")
    }
}
