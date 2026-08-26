//
//  FamilyShareReconcilerTests.swift
//  LootList
//
//  Created by Ben Mackin on 2026-08-12.
//

import CloudKit
import Foundation
@testable import LootList
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

@MainActor
struct FamilyShareReconcilerTests {
    private func makeContext(cloudKit: MockCloudKitService = MockCloudKitService()) -> ( // swiftlint:disable:this large_tuple
        reconciler: FamilyShareReconciler,
        cloudKit: MockCloudKitService,
        cache: CacheService,
        appState: AppState,
        zoneID: CKRecordZone.ID,
        family: Family,
        hero: Profile
    ) {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        cloudKit.activeFamilyZoneID = zoneID
        let appState = AppState()
        appState.isZoneOwner = true

        guard let cache = try? CacheService(inMemory: true) else {
            fatalError("Failed to initialize in-memory CacheService for tests")
        }
        let xpService = XPService(cloudKit: cloudKit, appState: appState)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService, appState: appState)
        let familyService = FamilyService(cloudKit: cloudKit, appState: appState, questService: questService, cacheService: cache)

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

        let reconciler = FamilyShareReconciler(
            familyService: familyService,
            // Fresh per-test suite so absence marks never leak between tests.
            defaults: UserDefaults(suiteName: "FamilyShareReconcilerTests.\(UUID().uuidString)")!
        )
        return (reconciler, cloudKit, cache, appState, zoneID, family, hero)
    }

    // MARK: - Absence Convergence

    @Test
    func `single participant-list absence does not deactivate a profile`() async {
        let ctx = makeContext()
        // No simulated participation: the hero's identity is absent from every
        // share. CloudKit propagates membership changes asynchronously, so one
        // observation must only record the absence, never deactivate.
        await ctx.reconciler.reconcileIfOwner()

        let fresh = ctx.cache.fetchProfiles(family: "fam1").first { $0.recordName == ctx.hero.id.recordName }
        #expect(fresh?.isActive == true)
    }

    @Test
    func `two consecutive absences deactivate the profile`() async {
        let ctx = makeContext()
        await ctx.reconciler.reconcileIfOwner()
        await ctx.reconciler.reconcileIfOwner()

        let fresh = ctx.cache.fetchProfiles(family: "fam1").first { $0.recordName == ctx.hero.id.recordName }
        #expect(fresh?.isActive == false)
    }

    @Test
    func `present identity keeps the profile active and clears absence marks`() async throws {
        let ctx = makeContext()
        // Pass 1: absent — the mark accumulates, nothing deactivates.
        await ctx.reconciler.reconcileIfOwner()
        #expect(ctx.cache.fetchProfiles(family: "fam1").first { $0.recordName == ctx.hero.id.recordName }?.isActive == true)

        // Membership propagates late (fresh join): pass 2 sees the identity
        // present and must clear the accumulated absence mark.
        _ = try await ctx.cloudKit.simulateParticipation(key: "record:u1", rootRecordID: ctx.family.id, role: .hero)
        await ctx.reconciler.reconcileIfOwner()
        #expect(ctx.cache.fetchProfiles(family: "fam1").first { $0.recordName == ctx.hero.id.recordName }?.isActive == true)

        // The identity drops off the share again (owner-side revoke). Because
        // the present pass cleared the mark, this absence restarts the count:
        // pass 3 must NOT deactivate — a stale mark would have made this the
        // second consecutive absence and deactivated the fresh join.
        try await ctx.cloudKit.removeParticipant(iCloudUserRecordName: "u1", from: ctx.family.id)
        await ctx.reconciler.reconcileIfOwner()
        #expect(ctx.cache.fetchProfiles(family: "fam1").first { $0.recordName == ctx.hero.id.recordName }?.isActive == true)
    }

    // MARK: - Explicit Revocation

    @Test
    func `removed participant deactivates immediately`() async throws {
        let ctx = makeContext()
        // Owner-side revoke leaves the identity visible with `.removed` status
        // while CloudKit propagates; this is an authoritative revoke, so a
        // single observation is enough.
        _ = try await ctx.cloudKit.simulateParticipation(key: "record:u1", rootRecordID: ctx.family.id, role: .hero)
        ctx.cloudKit.mockRemovedMemberships.insert("record:u1")
        await ctx.reconciler.reconcileIfOwner()

        let fresh = ctx.cache.fetchProfiles(family: "fam1").first { $0.recordName == ctx.hero.id.recordName }
        #expect(fresh?.isActive == false)
    }

    // MARK: - Fail-Closed Identity Resolution

    @Test
    func `identity resolution failure aborts the pass without deactivating`() async {
        let ctx = makeContext(cloudKit: FailingIdentityCloudKitService())
        // The identity is absent from the participant list, but the pass cannot
        // run the self-exclusion guard, so it must not deactivate anything.
        await ctx.reconciler.reconcileIfOwner()

        let fresh = ctx.cache.fetchProfiles(family: "fam1").first { $0.recordName == ctx.hero.id.recordName }
        #expect(fresh?.isActive == true)
    }
}
