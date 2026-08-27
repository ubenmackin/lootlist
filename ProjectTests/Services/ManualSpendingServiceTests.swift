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
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
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

        let entry = try await service.logManual(profile: hero, family: family, familyRecordName: family.id.recordName, description: "Test Buy", amount: 10.0)
        #expect(entry.amount == -10.0)

        let cached = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        #expect(!cached.isEmpty, "LedgerEntry must be written to cache immediately")
        #expect(cached.first?.amount == -10.0)
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
            amount: -15.0,
            description: "Existing item",
            date: Date(),
            source: "manual",
            family: familyRef
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
                amount: 10.0
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
            amount: -10.0,
            description: "Another hero's entry",
            date: Date(),
            source: "manual",
            family: makeFamilyRef(zoneID)
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
        #expect(cached.first?.amount == -10.0, "unauthorized delete must not touch the entry")
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
            amount: -10.0,
            description: "Hero's own entry",
            date: Date(),
            source: "manual",
            family: makeFamilyRef(zoneID)
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
            amount: -10.0,
            description: "Hero's entry under parent oversight",
            date: Date(),
            source: "manual",
            family: makeFamilyRef(zoneID)
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
            amount: 50.0,
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
        #expect(cached.first?.amount == 50.0, "quest entry must not be deleted")
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
            createdBy: CKRecord.ID(recordName: "parentA", zoneID: zoneID),
            id: CKRecord.ID(recordName: "famA", zoneID: zoneID)
        )
        let familyB = Family(
            name: "Family B",
            createdBy: CKRecord.ID(recordName: "parentB", zoneID: zoneID),
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
            amount: -7.5,
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
            amount: 12.0
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

        let entry = try await service.deposit(
            profile: hero,
            family: family,
            familyRecordName: family.id.recordName,
            description: "Birthday gift from Grandpa",
            amount: 25.0
        )

        #expect(entry.amount == 25.0)
        #expect(entry.source == "deposit")
        #expect(entry.description == "Birthday gift from Grandpa")

        let cached = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        #expect(cached.count == 1)
        #expect(cached.first?.amount == 25.0)
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
            amount: 10.0
        )

        #expect(entry.amount == -10.0)
        #expect(entry.source == "withdrawal")
        #expect(entry.description == "Camp cash")

        let cached = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        #expect(cached.count == 1)
        #expect(cached.first?.amount == -10.0)
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
            amount: 15.0,
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
        amount: Double,
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
        seedAttributedEntry(cache, recordName: "seed-spend", amount: 12.00, source: "quest",
                            bucketKind: BucketKind.spend.rawValue, profileID: hero.id,
                            familyRef: makeFamilyRef(zoneID), zoneID: zoneID)
        seedAttributedEntry(cache, recordName: "seed-short", amount: 5.00, source: "quest",
                            bucketKind: BucketKind.shortTermSave.rawValue, profileID: hero.id,
                            familyRef: makeFamilyRef(zoneID), zoneID: zoneID)
        seedAttributedEntry(cache, recordName: "seed-long", amount: 3.00, source: "quest",
                            bucketKind: BucketKind.longTermSave.rawValue, profileID: hero.id,
                            familyRef: makeFamilyRef(zoneID), zoneID: zoneID)

        let buckets = makeBucketService(cache: cache, appState: appState, cloudKit: cloudKit)

        let entry = try await service.logManual(
            profile: hero,
            family: family,
            familyRecordName: family.id.recordName,
            description: "Comic book",
            amount: 6.00
        )
        #expect(entry.amount == -6.00)
        #expect(entry.source == "manual")

        // Savings allocations are never silently drained by a purchase; the
        // unattributed purchase only lowers the aggregate wallet.
        let balances = buckets.bucketBalances(
            profileRecordName: hero.id.recordName,
            familyRecordName: family.id.recordName
        )
        #expect(balances[.spend] == 12.00)
        #expect(balances[.shortTermSave] == 5.00)
        #expect(balances[.longTermSave] == 3.00)

        let walletTotal = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
            .reduce(0.0) { $0 + $1.amount }
        #expect(walletTotal == 14.00)
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

        seedAttributedEntry(cache, recordName: "seed-spend", amount: 10.00, source: "quest",
                            bucketKind: BucketKind.spend.rawValue, profileID: hero.id,
                            familyRef: makeFamilyRef(zoneID), zoneID: zoneID)
        seedAttributedEntry(cache, recordName: "seed-short", amount: 4.00, source: "quest",
                            bucketKind: BucketKind.shortTermSave.rawValue, profileID: hero.id,
                            familyRef: makeFamilyRef(zoneID), zoneID: zoneID)
        // A purchase recorded against the Spend bucket leaves the save buckets intact.
        seedAttributedEntry(cache, recordName: "purchase-spend", amount: -6.00, source: "manual",
                            bucketKind: BucketKind.spend.rawValue, profileID: hero.id,
                            familyRef: makeFamilyRef(zoneID), zoneID: zoneID)

        let balances = buckets.bucketBalances(
            profileRecordName: hero.id.recordName,
            familyRecordName: family.id.recordName
        )
        #expect(balances[.spend] == 4.00)
        #expect(balances[.shortTermSave] == 4.00)
        #expect(balances[.longTermSave] == nil)
        #expect(balances.count == 2)
    }
}
