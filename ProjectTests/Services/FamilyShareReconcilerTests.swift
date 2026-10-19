//
//  FamilyShareReconcilerTests.swift
//  LootList
//
//  Created by Ben Mackin on 2026-08-12.
//

import CloudKit
import Foundation
@testable import LootList
import Synchronization
import Testing

/// `MockCloudKitService` that cannot resolve the current iCloud identity,
/// exercising the reconciler's deny-by-default self-exclusion guard.
@MainActor
private final class FailingIdentityCloudKitService: MockCloudKitService {
    private enum IdentityFailure: Error {
        case unresolved
    }

    override func currentUserRecordID() async throws -> CKRecord.ID {
        throw IdentityFailure.unresolved
    }
}

/// `MockCloudKitService` with a toggleable share-status fetch failure,
/// exercising the reconciler's fail-silent path on fetch errors.
@MainActor
private final class FailingStatusCloudKitService: MockCloudKitService {
    private enum StatusFailure: Error {
        case unavailable
    }

    var shouldFailStatusFetch = false

    override func fetchShareParticipantStatuses(for rootRecordID: CKRecord.ID) async throws -> [ShareParticipantStatus] {
        if shouldFailStatusFetch {
            throw StatusFailure.unavailable
        }
        return try await super.fetchShareParticipantStatuses(for: rootRecordID)
    }
}

@MainActor
struct FamilyShareReconcilerTests {
    private struct Context {
        let reconciler: FamilyShareReconciler
        let cloudKit: MockCloudKitService
        let cache: CacheService
        let appState: AppState
        let zoneID: CKRecordZone.ID
        let family: Family
        let hero: Profile
    }

    private func makeContext(cloudKit: MockCloudKitService = MockCloudKitService()) -> Context {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        cloudKit.activeFamilyZoneID = zoneID
        let appState = AppState()
        appState.isZoneOwner = true

        let cache = CacheService.inMemoryFallback()
        let xpService = XPService(cloudKit: cloudKit, appState: appState)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService, appState: appState)
        let familyService = FamilyService(cloudKit: cloudKit, appState: appState, questService: questService, cacheService: cache)

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let family = Family(
            name: "Test Guild",
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let hero = Profile(
            displayName: "Hero",
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

        cloudKit.seedMockRecords([family, hero])
        cache.context?.insert(FamilyCache(from: family))
        cache.context?.insert(ProfileCache(from: hero))
        _ = cache.saveContext()
        appState.family = family
        // The owner's device acts as Guild Master, so deactivation is
        // authorized through the parent-role guard in `deactivateProfile`.
        appState.currentProfile = guildMaster

        let reconciler = FamilyShareReconciler(familyService: familyService)
        return Context(
            reconciler: reconciler,
            cloudKit: cloudKit,
            cache: cache,
            appState: appState,
            zoneID: zoneID,
            family: family,
            hero: hero
        )
    }

    // MARK: - Positive-Evidence Deactivation

    @Test
    func `pending invite plus stale removed entry for one identity never deactivates`() async throws {
        let ctx = makeContext()
        // The kid was re-invited: a stale `.removed` record entry coexists with a fresh
        // email-keyed pending entry carrying no resolved record name yet, mirroring
        // `fetchShareParticipantStatuses` output for a re-invited member.
        _ = try await ctx.cloudKit.simulateParticipation(key: "record:u1", rootRecordID: ctx.family.id, role: .hero)
        ctx.cloudKit.mockRemovedMemberships.insert("record:u1")
        _ = try await ctx.cloudKit.simulatePendingParticipation(key: "email:hero@example.com", rootRecordID: ctx.family.id, role: .hero)
        await ctx.reconciler.reconcileIfOwner()
        await ctx.reconciler.reconcileIfOwner()

        let fresh = ctx.cache.fetchProfiles(family: "fam1").first { $0.recordName == ctx.hero.id.recordName }
        #expect(fresh?.isActive == true)
    }

    @Test
    func `single removed entry deactivates and posts familyRosterChanged`() async throws {
        let ctx = makeContext()
        _ = try await ctx.cloudKit.simulateParticipation(key: "record:u1", rootRecordID: ctx.family.id, role: .hero)
        // Owner-side revoke leaves the identity visible with `.removed` status
        // while CloudKit propagates; this is an authoritative revoke, so a
        // single observation is enough.
        ctx.cloudKit.mockRemovedMemberships.insert("record:u1")

        let rosterChangeCount = Mutex(0)
        let observer = NotificationCenter.default.addObserver(
            forName: .familyRosterChanged, object: nil, queue: nil
        ) { _ in
            rosterChangeCount.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await ctx.reconciler.reconcileIfOwner()

        #expect(rosterChangeCount.withLock { $0 } == 1)
        let fresh = ctx.cache.fetchProfiles(family: "fam1").first { $0.recordName == ctx.hero.id.recordName }
        #expect(fresh?.isActive == false)
    }

    @Test
    func `profile with no participant entry is never deactivated`() async {
        let ctx = makeContext()
        // CloudKit propagates membership asynchronously, but absence from the
        // participant list is negative evidence: however many passes run, the
        // profile must stay active.
        for _ in 0 ..< 3 {
            await ctx.reconciler.reconcileIfOwner()
        }

        let fresh = ctx.cache.fetchProfiles(family: "fam1").first { $0.recordName == ctx.hero.id.recordName }
        #expect(fresh?.isActive == true)
    }

    // MARK: - Status Mapping

    @Test
    func `status mapping keeps pending participants pending and records accepted record names`() async throws {
        let cloudKit = MockCloudKitService()
        let familyID = CKRecord.ID(recordName: "fam-map", zoneID: CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner"))

        _ = try await cloudKit.simulateParticipation(key: "record:u1", rootRecordID: familyID, role: .hero)
        _ = try await cloudKit.simulatePendingParticipation(key: "record:reinvite", rootRecordID: familyID, role: .hero)

        let statuses = try await cloudKit.fetchShareParticipantStatuses(for: familyID)

        let accepted = statuses.first { $0.identityKey == "record:u1" }
        #expect(accepted?.recordName == "u1")
        #expect(accepted?.isPending == false)
        #expect(accepted?.isRemoved == false)

        let pending = statuses.first { $0.identityKey == "record:reinvite" }
        #expect(pending?.isPending == true)
        // CloudKit resolves the user record only on acceptance, so a pending
        // entry must never carry a record name.
        #expect(pending?.recordName == nil)
        #expect(pending?.isRemoved == false)
    }

    // MARK: - Fail-Closed Guards

    @Test
    func `identity resolution failure aborts the pass without deactivating`() async {
        let ctx = makeContext(cloudKit: FailingIdentityCloudKitService())
        // The pass cannot run the self-exclusion guard, so it must abort and
        // never touch active profiles.
        await ctx.reconciler.reconcileIfOwner()

        let fresh = ctx.cache.fetchProfiles(family: "fam1").first { $0.recordName == ctx.hero.id.recordName }
        #expect(fresh?.isActive == true)
    }

    @Test
    func `failed status fetch deactivates nobody`() async throws {
        let failingCloudKit = FailingStatusCloudKitService()
        let ctx = makeContext(cloudKit: failingCloudKit)
        failingCloudKit.shouldFailStatusFetch = true
        await ctx.reconciler.reconcileIfOwner()
        await ctx.reconciler.reconcileIfOwner()

        let afterFailures = ctx.cache.fetchProfiles(family: "fam1").first { $0.recordName == ctx.hero.id.recordName }
        #expect(afterFailures?.isActive == true)

        // Once the share resolves again, an explicit revocation still deactivates.
        _ = try await ctx.cloudKit.simulateParticipation(key: "record:u1", rootRecordID: ctx.family.id, role: .hero)
        ctx.cloudKit.mockRemovedMemberships.insert("record:u1")
        failingCloudKit.shouldFailStatusFetch = false
        await ctx.reconciler.reconcileIfOwner()

        let afterRevoke = ctx.cache.fetchProfiles(family: "fam1").first { $0.recordName == ctx.hero.id.recordName }
        #expect(afterRevoke?.isActive == false)
    }
}
