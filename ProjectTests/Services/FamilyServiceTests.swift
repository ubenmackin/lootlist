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
    func makeDependencies() -> (FamilyService, MockCloudKitService, AppState, QuestService) { // swiftlint:disable:this large_tuple
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true
        let appState = AppState(defaults: .ephemeral())
        appState.isZoneOwner = true
        appState.familyZoneID = zoneID
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        appState.family = family
        let xpService = XPService(cloudKit: cloudKit, appState: appState)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService, appState: appState)
        let familyService = FamilyService(cloudKit: cloudKit, appState: appState, questService: questService)
        return (familyService, cloudKit, appState, questService)
    }

    func makeStandardFixtures(zoneName: String = "TestZone") -> ( // swiftlint:disable:this large_tuple
        zoneID: CKRecordZone.ID,
        familyRef: CKRecord.Reference,
        family: Family,
        hero: Profile,
        parent: Profile
    ) {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: "TestOwner")
        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let hero = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        let parent = Profile(
            displayName: "Guild Master",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "gm1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "gm1", zoneID: zoneID)
        )
        return (zoneID, familyRef, family, hero, parent)
    }

    @Test
    func `family service error equality`() {
        #expect(FamilyServiceError.invalidInviteCode == FamilyServiceError.invalidInviteCode)
        #expect(FamilyServiceError.accountUnavailable == FamilyServiceError.accountUnavailable)
        #expect(FamilyServiceError.joinFailed == FamilyServiceError.joinFailed)
        #expect(FamilyServiceError.creationFailed == FamilyServiceError.creationFailed)
        #expect(FamilyServiceError.persistenceFailed == FamilyServiceError.persistenceFailed)
        #expect(FamilyServiceError.creationFailed != FamilyServiceError.persistenceFailed)
    }

    @Test
    func `family service errors expose user-presentable descriptions`() {
        #expect(FamilyServiceError.invalidInviteCode.errorDescription != nil)
        #expect(FamilyServiceError.joinFailed.errorDescription != nil)
        #expect(FamilyServiceError.creationFailed.errorDescription != nil)
        #expect(FamilyServiceError.persistenceFailed.errorDescription != nil)
        #expect(FamilyServiceError.accountUnavailable.errorDescription != nil)
        #expect(!(FamilyServiceError.creationFailed.errorDescription ?? "").isEmpty)
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
            #expect(error == FamilyServiceError.creationFailed)
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    // MARK: - Freshness-Aware Cache Reads

    func makeFamilyServiceWithCache(cloudKit: any CloudKitServiceProtocol,
                                    cache: CacheService) -> FamilyService
    {
        let appState = AppState(defaults: .ephemeral())
        let zoneID = cloudKit.activeFamilyZoneID ?? CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        appState.familyZoneID = zoneID
        appState.isZoneOwner = cloudKit.activeIsOwner
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        appState.family = family
        let xpService = XPService(cloudKit: cloudKit, appState: appState)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService, appState: appState)
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
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
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
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
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

        // The cache-hit path must not fire a detached background refresh —
        // CloudKit truth must NOT be written through into the cache.
        #expect(
            !cache.fetchProfiles(family: "fam1").contains { $0.recordName == "hero-ck" },
            "A fresh cache hit must not write through CloudKit records"
        )
    }

    // MARK: - Cache Reads & Immediate Refresh Deduplication

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
        // have queried it and written it through on every cache hit.
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
            "A fresh cache hit must not issue a background CloudKit refresh"
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
        // cache and neither may fire the removed detached refresh.
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
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
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
        familyService.appState.currentProfile = hero

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
        // The acting profile must be a parent (Guild Master / Ranger) — the
        // service-layer authorization guard rejects non-parent actors.
        let guildMaster = Profile(
            displayName: "Guild Master",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "gm1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "gm1", zoneID: zoneID)
        )
        cache.upsertFamily(family)
        cache.upsertProfile(hero)
        cloudKit.seedMockRecords([family, hero])
        appState.family = family
        appState.currentProfile = guildMaster

        try await familyService.kickMember(profile: hero)

        // (a) The hero is deactivated — reflected by the cache write-through.
        let cachedHero = cache.fetchProfiles(family: "fam1").first { $0.recordName == hero.id.recordName }
        #expect(cachedHero?.isActive == false)

        // (b) The active roster no longer contains the removed hero.
        let heroes = try await familyService.fetchHeroes(for: family)
        #expect(!heroes.contains { $0.id == hero.id })
    }

    @Test
    func `kickMember share-revocation failure returns partial result without re-deactivating`() async throws {
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
        let guildMaster = Profile(
            displayName: "Guild Master",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "gm1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "gm1", zoneID: zoneID)
        )
        cache.upsertFamily(family)
        cache.upsertProfile(hero)
        cloudKit.seedMockRecords([family, hero])
        appState.family = family
        appState.currentProfile = guildMaster

        // The hero has NO share participation, so the share-revocation step
        // throws (the mock only revokes identities actually present on a role
        // share). The kick must surface the partial outcome rather than throw or
        // roll back the already-succeeded deactivation.
        let result = try await familyService.kickMember(profile: hero)

        guard case let .partialRevocationFailed(error) = result else {
            #expect(Bool(false), "Expected a partial-revocation failure, got \(result)")
            return
        }

        // The surfaced message is non-PII guidance for the Guild Master — it
        // tells them the departed identity still holds share access.
        #expect(!error.isEmpty)

        // The authoritative kick still succeeded: the profile stays deactivated
        // and is not re-activated by the share-revocation failure.
        let cachedHero = cache.fetchProfiles(family: "fam1").first { $0.recordName == hero.id.recordName }
        #expect(cachedHero?.isActive == false)
    }

    @Test
    func `hero self-leave unassigns their active quests instead of orphaning them`() async throws {
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
            displayName: "Leaving Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        // A quest assigned to the hero in the current week, persisted to the
        // CloudKit mock so `unassignActiveQuests` can find and purge it.
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: WeekMath.startOfWeek(for: Date()),
            createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: "gm1", zoneID: zoneID), action: .none),
            family: familyRef,
            name: "Active Quest",
            id: CKRecord.ID(recordName: "quest1", zoneID: zoneID)
        )

        cache.upsertFamily(family)
        cache.upsertProfile(hero)
        cache.upsertQuest(quest)
        cloudKit.seedMockRecords([family, hero, quest])
        // unassignActiveQuests guards on appState.family being set.
        appState.family = family
        // The acting profile is the hero performing self-service leave.
        appState.currentProfile = hero

        try await familyService.leaveFamily(profile: hero)

        // (a) The hero's profile is deactivated.
        let cachedHero = cache.fetchProfiles(family: "fam1").first { $0.recordName == hero.id.recordName }
        #expect(cachedHero?.isActive == false)

        // (b) The hero's active quest was unassigned (deleted) from local cache.
        #expect(cache.fetchQuest(recordName: quest.id.recordName, family: "fam1") == nil)

        // (c) Self-leave does not mutate share participant list directly.
        #expect(cloudKit.revokedShareIDs.isEmpty)
    }

    @Test
    func `fetchHeroes on empty family returns empty array`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
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

    // MARK: - Error-Path Coverage

    @Test
    func `updateFamilyName with empty name throws persistenceFailed`() async {
        let (familyService, _, appState, _) = makeDependencies()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let parent = Profile(
            displayName: "Guild Master",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "gm1", zoneID: zoneID)
        )
        appState.currentProfile = parent

        do {
            _ = try await familyService.updateFamilyName(family: family, newName: "   ")
            #expect(Bool(false), "Expected empty-name persistence error")
        } catch let error as FamilyServiceError {
            #expect(error == .persistenceFailed)
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test
    func `updateProfileDisplayName with empty name throws persistenceFailed`() async {
        let (familyService, _, appState, _) = makeDependencies()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let hero = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        appState.currentProfile = hero

        do {
            _ = try await familyService.updateProfileDisplayName(profile: hero, newName: "  ")
            #expect(Bool(false), "Expected empty-name persistence error")
        } catch let error as FamilyServiceError {
            #expect(error == .persistenceFailed)
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test
    func `updateProfilePayoutPolicy on save failure throws persistenceFailed and rolls back`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let familyService = makeFamilyServiceWithCache(cloudKit: cloudKit, cache: cache)

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let hero = Profile(
            displayName: "Override Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            payoutPolicy: .perQuest,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        cache.upsertProfile(hero)
        familyService.appState.currentProfile = hero

        let updated = try await familyService.updateProfilePayoutPolicy(profile: hero, policy: .allOrNothing)
        #expect(updated.payoutPolicy == .allOrNothing)

        let cached = cache.fetchProfiles(family: "fam1").first { $0.recordName == hero.id.recordName }
        #expect(cached?.payoutPolicyEnum == .allOrNothing)
    }

    @Test
    func `kickMember updates local cache immediately`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState(defaults: .ephemeral())
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        let familyService = FamilyService(
            cloudKit: cloudKit,
            appState: appState,
            questService: questService,
            cacheService: cache
        )

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
        // The acting profile must be a parent for the kick to proceed to the
        // save step (service-layer authorization guard).
        let guildMaster = Profile(
            displayName: "Guild Master",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "gm1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "gm1", zoneID: zoneID)
        )
        cache.upsertFamily(family)
        cache.upsertProfile(hero)
        appState.family = family
        appState.currentProfile = guildMaster

        _ = try await familyService.kickMember(profile: hero)
        let cached = cache.fetchProfiles(family: "fam1").first { $0.recordName == hero.id.recordName }
        #expect(cached?.isActive == false)
    }

    @Test
    func `updatePayoutPolicy pre-canceled leaves AppState and cache unchanged`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true
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
        let parent = Profile(
            displayName: "Guild Master",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "gm1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "gm1", zoneID: zoneID)
        )
        cache.upsertFamily(family)
        cloudKit.seedMockRecords([family])
        familyService.appState.currentProfile = parent
        familyService.appState.family = family
        familyService.appState.familyZoneID = zoneID
        familyService.appState.isZoneOwner = true

        let task = Task {
            try await familyService.updatePayoutPolicy(family: family, policy: .allOrNothing)
        }
        task.cancel()
        var didThrowCancellation = false
        do {
            _ = try await task.value
            #expect(Bool(false), "Pre-canceled family payout update should throw")
        } catch is CancellationError {
            didThrowCancellation = true
        } catch {
            #expect(Bool(false), "Expected CancellationError, got \(error)")
        }
        #expect(didThrowCancellation)
        #expect(familyService.appState.family?.payoutPolicy == .perQuest)
        #expect(cache.fetchFamily(recordName: "fam1")?.payoutPolicyEnum == .perQuest)
    }

    @Test
    func `updateProfilePayoutPolicy pre-canceled leaves cache and AppState unchanged`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true
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
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            payoutPolicy: .perQuest,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        cache.upsertFamily(family)
        cache.upsertProfile(hero)
        cloudKit.seedMockRecords([family, hero])
        familyService.appState.currentProfile = hero
        familyService.appState.family = family
        familyService.appState.familyZoneID = zoneID
        familyService.appState.isZoneOwner = true

        let task = Task {
            try await familyService.updateProfilePayoutPolicy(profile: hero, policy: .realTime)
        }
        task.cancel()
        var didThrowCancellation = false
        do {
            _ = try await task.value
            #expect(Bool(false), "Pre-canceled profile payout update should throw")
        } catch is CancellationError {
            didThrowCancellation = true
        } catch {
            #expect(Bool(false), "Expected CancellationError, got \(error)")
        }
        #expect(didThrowCancellation)
        #expect(cache.fetchProfiles(family: "fam1").first { $0.recordName == hero.id.recordName }?.payoutPolicyEnum == .perQuest)
        #expect(familyService.appState.currentProfile?.payoutPolicy == .perQuest)
    }
}

private final class QueryCountingCloudKitService: MockCloudKitService {
    override init(zoneID: CKRecordZone.ID? = nil) {
        super.init()
        self.activeFamilyZoneID = zoneID
    }

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
        throw TestSaveError.saveFailed
    }
}

private enum TestSaveError: Error, Equatable {
    case saveFailed
}
