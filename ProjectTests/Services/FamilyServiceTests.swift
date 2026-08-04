//
//  FamilyServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Synchronization
import Testing

@MainActor
struct FamilyServiceTests {
    private func makeDependencies() -> (FamilyService, CloudKitService, AppState, QuestService) { // swiftlint:disable:this large_tuple
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let appState = AppState()
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        let familyService = FamilyService(cloudKit: cloudKit, appState: appState, questService: questService)
        return (familyService, cloudKit, appState, questService)
    }

    @Test
    func `family service error equality`() {
        #expect(FamilyServiceError.invalidInviteCode == FamilyServiceError.invalidInviteCode)
        #expect(FamilyServiceError.accountUnavailable == FamilyServiceError.accountUnavailable)
        #expect(FamilyServiceError.joinFailed("e1") == FamilyServiceError.joinFailed("e1"))
        #expect(FamilyServiceError.joinFailed("e1") != FamilyServiceError.joinFailed("e2"))
        #expect(FamilyServiceError.creationFailed("c1") == FamilyServiceError.creationFailed("c1"))
        #expect(FamilyServiceError.persistenceFailed("p1") == FamilyServiceError.persistenceFailed("p1"))
    }

    @Test
    func `create family empty name validation`() async {
        let (familyService, _, _, _) = makeDependencies()
        let dummyZone = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: dummyZone), action: .none)
        let profile = Profile(
            displayName: "Test GM",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: dummyZone),
            family: familyRef
        )

        do {
            _ = try await familyService.createFamily(name: "   ", ownerProfile: profile)
            #expect(Bool(false), "Expected empty name error")
        } catch let error as FamilyServiceError {
            #expect(error == FamilyServiceError.creationFailed("Family name cannot be empty."))
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    // MARK: - Freshness-Aware Cache Reads (D4)

    private func makeFamilyServiceWithCache(cloudKit: CloudKitService,
                                            cache: CacheService) -> FamilyService
    {
        let appState = AppState()
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        return FamilyService(
            cloudKit: cloudKit,
            appState: appState,
            questService: questService,
            cacheService: cache
        )
    }

    @Test
    func `fetchHeroes falls back to CloudKit when cache is stale`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let familyService = makeFamilyServiceWithCache(cloudKit: cloudKit, cache: cache)

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        // Partial cache: a hero WITHOUT a freshness stamp (stale). Explicitly
        // invalidate first — stamps persist in UserDefaults for the process,
        // so a fresh-gate test running earlier must not contaminate this one.
        cache.invalidateFreshness(familyRecordName: "fam1", type: .profile)
        let cachedHero = Profile(
            displayName: "Cached Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero-cached", zoneID: zoneID)
        )
        cache.upsertProfile(cachedHero)

        // CloudKit truth: a DIFFERENT hero in the same family.
        let ckHero = Profile(
            displayName: "CK Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u2", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero-ck", zoneID: zoneID)
        )
        cloudKit.seedMockRecords([ckHero])

        let heroes = try await familyService.fetchHeroes(for: family)

        // A stale (unstamped) partial cache must NOT be served — CloudKit wins.
        #expect(heroes.count == 1)
        #expect(heroes.first?.displayName == "CK Hero")
    }

    @Test
    func `fetchHeroes serves partial cache when freshness stamp is fresh`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let familyService = makeFamilyServiceWithCache(cloudKit: cloudKit, cache: cache)

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        // Partial cache: a hero WITH a freshness stamp (fresh).
        let cachedHero = Profile(
            displayName: "Cached Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero-cached", zoneID: zoneID)
        )
        cache.upsertProfile(cachedHero)
        cache.markCacheFresh(familyRecordName: "fam1", type: .profile)

        // CloudKit holds a DIFFERENT hero — if the gate leaked to CK the
        // result would differ from the cache.
        let ckHero = Profile(
            displayName: "CK Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u2", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero-ck", zoneID: zoneID)
        )
        cloudKit.seedMockRecords([ckHero])

        let heroes = try await familyService.fetchHeroes(for: family)

        // Fresh partial cache wins — CloudKit is never consulted.
        #expect(heroes.count == 1)
        #expect(heroes.first?.displayName == "Cached Hero")

        // R2: the cache-hit path must not fire a detached background refresh —
        // CloudKit truth must NOT be written through into the cache.
        #expect(
            !cache.fetchProfiles(family: "fam1").contains { $0.recordName == "hero-ck" },
            "A fresh cache hit must not write through CloudKit records"
        )
    }

    // MARK: - R2: No Detached Refresh on Cache-Hit / Deduped Immediate Refresh

    /// Counts CloudKit `query` calls (mock-backed, no network) so tests can
    /// assert a fresh-cache read issues zero queries and concurrent immediate
    /// refreshes collapse to one.
    private final class QueryCountingCloudKitService: CloudKitService {
        private(set) var queryCallCount = 0

        override func query<T: CloudKitRecord>(
            _: T.Type,
            predicate: NSPredicate,
            in zoneID: CKRecordZone.ID? = nil,
            sortDescriptors: [NSSortDescriptor]? = nil,
            using db: CKDatabase? = nil
        ) async throws -> [T] {
            queryCallCount += 1
            return try await super.query(T.self, predicate: predicate, in: zoneID, sortDescriptors: sortDescriptors, using: db)
        }
    }

    /// Parks `query` calls until released, opening a deterministic in-flight
    /// window so a second concurrent immediate refresh can be observed
    /// collapsing onto the first (actor-isolated in-flight guard).
    private final class GatedQueryCloudKitService: CloudKitService {
        private let gate = QueryGate()
        private(set) var queryCallCount = 0

        override func query<T: CloudKitRecord>(
            _: T.Type,
            predicate: NSPredicate,
            in zoneID: CKRecordZone.ID? = nil,
            sortDescriptors: [NSSortDescriptor]? = nil,
            using db: CKDatabase? = nil
        ) async throws -> [T] {
            queryCallCount += 1
            await gate.park()
            return try await super.query(T.self, predicate: predicate, in: zoneID, sortDescriptors: sortDescriptors, using: db)
        }

        func releaseQueries() {
            gate.releaseAll()
        }
    }

    /// Holds parked `query` continuations behind a `Mutex` so a `@Sendable`
    /// closure can park without touching main-actor state (Swift 6 safe).
    private final class QueryGate: Sendable {
        private let lock = Mutex<[CheckedContinuation<Void, Never>]>([])

        func park() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { $0.append(continuation) }
            }
        }

        func releaseAll() {
            let parked = lock.withLock { continuations -> [CheckedContinuation<Void, Never>] in
                let all = continuations
                continuations.removeAll()
                return all
            }
            for continuation in parked {
                continuation.resume()
            }
        }
    }

    @Test
    func `fetchHeroes on a fresh cache performs no CloudKit query`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = QueryCountingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let familyService = makeFamilyServiceWithCache(cloudKit: cloudKit, cache: cache)

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        // Fresh cache: a hero WITH a freshness stamp. Stamps persist in
        // UserDefaults for the process, so invalidate first to isolate.
        cache.invalidateFreshness(familyRecordName: "fam1", type: .profile)
        let cachedHero = Profile(
            displayName: "Cached Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero-cached", zoneID: zoneID)
        )
        cache.upsertProfile(cachedHero)
        cache.markCacheFresh(familyRecordName: "fam1", type: .profile)

        // CloudKit holds a DIFFERENT hero — the removed detached refresh would
        // have queried it and written it through on every cache hit (R2).
        let ckHero = Profile(
            displayName: "CK Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u2", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero-ck", zoneID: zoneID)
        )
        cloudKit.seedMockRecords([ckHero])

        let heroes = try await familyService.fetchHeroes(for: family)

        #expect(heroes.count == 1)
        #expect(heroes.first?.displayName == "Cached Hero")
        #expect(
            cloudKit.queryCallCount == 0,
            "A fresh cache hit must not issue a background CloudKit refresh (R2)"
        )
        #expect(
            !cache.fetchProfiles(family: "fam1").contains { $0.recordName == "hero-ck" },
            "No detached refresh may write CloudKit truth into the cache"
        )
    }

    @Test
    func `concurrent fresh-cache reads issue no duplicate CloudKit queries`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = QueryCountingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let familyService = makeFamilyServiceWithCache(cloudKit: cloudKit, cache: cache)

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        cache.invalidateFreshness(familyRecordName: "fam1", type: .profile)
        let cachedHero = Profile(
            displayName: "Cached Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero-cached", zoneID: zoneID)
        )
        cache.upsertProfile(cachedHero)
        cache.markCacheFresh(familyRecordName: "fam1", type: .profile)

        let ckHero = Profile(
            displayName: "CK Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u2", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero-ck", zoneID: zoneID)
        )
        cloudKit.seedMockRecords([ckHero])

        // Two concurrent callers on a fresh cache: both must be served from
        // cache and neither may fire the removed detached refresh (R2).
        let service = familyService
        let first = Task { try await service.fetchHeroes(for: family) }
        let second = Task { try await service.fetchAllProfilesForFamily(family) }
        let (heroes, profiles) = try await (first.value, second.value)

        #expect(heroes.first?.displayName == "Cached Hero")
        #expect(profiles.first?.displayName == "Cached Hero")
        #expect(
            cloudKit.queryCallCount == 0,
            "Concurrent fresh-cache reads must not duplicate CloudKit queries"
        )
        #expect(
            !cache.fetchProfiles(family: "fam1").contains { $0.recordName == "hero-ck" },
            "No concurrent read may write CloudKit truth into the cache"
        )
    }

    @Test
    func `concurrent immediate refreshes collapse to one CloudKit query`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = GatedQueryCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let familyService = makeFamilyServiceWithCache(cloudKit: cloudKit, cache: cache)

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let ckHero = Profile(
            displayName: "CK Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u2", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero-ck", zoneID: zoneID)
        )
        cloudKit.seedMockRecords([ckHero])

        // First immediate refresh parks inside the CloudKit query, holding the
        // in-flight guard for operation + family.
        let service = familyService
        let first = Task { await service.refreshProfilesFromCloudKit(for: family) }
        await Task.yield()

        // Second refresh for the same operation + family while the first is in
        // flight: must collapse onto it instead of issuing a duplicate query.
        let second = Task { await service.refreshProfilesFromCloudKit(for: family) }
        await Task.yield()

        #expect(
            cloudKit.queryCallCount == 1,
            "Concurrent immediate refreshes for the same family must collapse to one query"
        )

        cloudKit.releaseQueries()
        await first.value
        await second.value

        // Exactly one write-through landed with the queried roster.
        let profiles = cache.fetchProfiles(family: "fam1")
        #expect(profiles.count == 1)
        #expect(profiles.first?.recordName == "hero-ck")
    }

    // MARK: - Profile Payout Policy Override, Membership Removal & Empty Roster

    @Test
    func `updateProfilePayoutPolicy persists profile override`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let familyService = makeFamilyServiceWithCache(cloudKit: cloudKit, cache: cache)

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            payoutPolicy: .perQuest,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let hero = Profile(
            displayName: "Override Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            payoutPolicy: .perQuest,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        cache.upsertFamily(family)
        cache.upsertProfile(hero)
        cloudKit.seedMockRecords([family, hero])

        let saved = try await familyService.updateProfilePayoutPolicy(profile: hero, policy: .allOrNothing)

        // (a) The returned profile carries the profile-level override.
        #expect(saved.payoutPolicy == .allOrNothing)

        // (b) The cache reflects the override for the hero.
        let cached = cache.fetchProfiles(family: "fam1").first { $0.recordName == hero.id.recordName }
        #expect(cached?.payoutPolicyEnum == .allOrNothing)

        // (c) Precedence contract: the profile-level override wins over the
        // family-level policy (`profile ?? family` resolves to the override).
        #expect((cached?.payoutPolicyEnum ?? family.payoutPolicy) == .allOrNothing)
    }

    @Test
    func `kickMember removes hero from active roster`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let hero = Profile(
            displayName: "Kicked Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        cache.upsertFamily(family)
        cache.upsertProfile(hero)
        cloudKit.seedMockRecords([family, hero])
        appState.family = family

        try await familyService.kickMember(profile: hero)

        // (a) The hero is deactivated — persisted in the CloudKit mock and
        // reflected by the cache write-through.
        let freshHero = try await cloudKit.fetch(Profile.self, id: hero.id)
        #expect(freshHero.isActive == false)
        let cachedHero = cache.fetchProfiles(family: "fam1").first { $0.recordName == hero.id.recordName }
        #expect(cachedHero?.isActive == false)

        // (b) The active roster no longer contains the removed hero.
        let heroes = try await familyService.fetchHeroes(for: family)
        #expect(!heroes.contains { $0.id == hero.id })
    }

    @Test
    func `fetchHeroes on empty family returns empty array`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let familyService = makeFamilyServiceWithCache(cloudKit: cloudKit, cache: cache)

        // Empty family: no profiles seeded in the cache or the CloudKit mock.
        let family = Family(
            name: "Empty Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        let heroes = try await familyService.fetchHeroes(for: family)

        #expect(heroes.isEmpty)
    }
}
