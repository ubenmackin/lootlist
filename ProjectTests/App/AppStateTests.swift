//
//  AppStateTests.swift
//  LootList
//
//  Created by Ben Mackin on 2026-08-04
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct AppStateTests {
    @Test
    func `restore session from cache preserves family payout day`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "RestoreZone", ownerName: "RestoreOwner")
        let recordName = "fam1"
        let familyID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let profileID = CKRecord.ID(recordName: "prof1", zoneID: zoneID)

        // Family configured with a Friday payout day.
        let family = Family(
            name: "Offline Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            payoutPolicy: .perQuest,
            payoutDay: .friday,
            id: familyID
        )
        let profile = Profile(
            displayName: "Offline GM",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            family: CKRecord.Reference(recordID: familyID, action: .none),
            id: profileID
        )

        // Seed the cache with the offline-rehydration source rows.
        let defaults = UserDefaults.ephemeral()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        cache.upsertFamily(family)
        cache.upsertProfile(profile)

        let appState = AppState(defaults: defaults)
        appState.cacheService = cache
        appState.saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: true)

        let cloudKit = MockCloudKitService()
        cloudKit.fetchError = CloudKitServiceError.retryable(attempt: 1, code: nil)
        await appState.restoreSession(cloudKit: cloudKit)

        #expect(appState.authStatus == .authenticated)
        // The reconstructed Family must retain the configured payout day rather
        // than falling back to the structural default.
        #expect(appState.family?.payoutDay == .friday)
    }

    @Test
    func `sign out purges only the signed out family cache`() throws {
        // Seed the in-memory cache with rows for three families. Only familyA
        // is the active session; sign-out must drop familyA's rows while
        // leaving familyB and familyC untouched (targeted purge, not clearAll).
        let zoneA = CKRecordZone.ID(zoneName: "familyA", ownerName: "ownerA")
        let zoneB = CKRecordZone.ID(zoneName: "familyB", ownerName: "ownerB")
        let zoneC = CKRecordZone.ID(zoneName: "familyC", ownerName: "ownerC")

        let familyAID = CKRecord.ID(recordName: "familyA", zoneID: zoneA)
        let familyBID = CKRecord.ID(recordName: "familyB", zoneID: zoneB)
        let familyCID = CKRecord.ID(recordName: "familyC", zoneID: zoneC)

        let familyA = Family(
            name: "Guild A",
            createdBy: CKRecord.ID(recordName: "ownerA", zoneID: zoneA),
            id: familyAID
        )
        let familyB = Family(
            name: "Guild B",
            createdBy: CKRecord.ID(recordName: "ownerB", zoneID: zoneB),
            id: familyBID
        )
        let familyC = Family(
            name: "Guild C",
            createdBy: CKRecord.ID(recordName: "ownerC", zoneID: zoneC),
            id: familyCID
        )

        let profileA = Profile(
            displayName: "Hero A",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "ownerA", zoneID: zoneA),
            family: CKRecord.Reference(recordID: familyAID, action: .none),
            id: CKRecord.ID(recordName: "profA", zoneID: zoneA)
        )
        let profileB = Profile(
            displayName: "Hero B",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "ownerB", zoneID: zoneB),
            family: CKRecord.Reference(recordID: familyBID, action: .none),
            id: CKRecord.ID(recordName: "profB", zoneID: zoneB)
        )
        let profileC = Profile(
            displayName: "Hero C",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "ownerC", zoneID: zoneC),
            family: CKRecord.Reference(recordID: familyCID, action: .none),
            id: CKRecord.ID(recordName: "profC", zoneID: zoneC)
        )

        let defaults = UserDefaults.ephemeral()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        cache.upsertFamily(familyA)
        cache.upsertFamily(familyB)
        cache.upsertFamily(familyC)
        cache.upsertProfile(profileA)
        cache.upsertProfile(profileB)
        cache.upsertProfile(profileC)

        let appState = AppState(defaults: defaults)
        appState.cacheService = cache
        appState.saveSession(profile: profileA, family: familyA, zoneID: zoneA, isOwner: true)

        appState.signOut()

        // The signed-out family's rows are gone.
        #expect(cache.fetchFamily(recordName: "familyA") == nil)
        #expect(cache.fetchProfiles(family: "familyA").isEmpty)

        // The other two families survived the targeted purge.
        #expect(cache.fetchFamily(recordName: "familyB") != nil)
        #expect(cache.fetchFamily(recordName: "familyC") != nil)
        #expect(cache.fetchProfiles(family: "familyB").map(\.recordName) == ["profB"])
        #expect(cache.fetchProfiles(family: "familyC").map(\.recordName) == ["profC"])
    }

    @Test
    func `cross-device profile field changes propagate to current profile`() throws {
        let zoneID = CKRecordZone.ID(zoneName: "PropagationZone", ownerName: "PropagationOwner")
        let familyID = CKRecord.ID(recordName: "famProp", zoneID: zoneID)
        let profileID = CKRecord.ID(recordName: "profProp", zoneID: zoneID)

        let family = Family(
            name: "Propagation Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: familyID
        )
        let profile = Profile(
            displayName: "Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "hero1", zoneID: zoneID),
            family: CKRecord.Reference(recordID: familyID, action: .none),
            payoutPolicy: .perQuest,
            id: profileID
        )

        let defaults = UserDefaults.ephemeral()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        cache.upsertFamily(family)
        cache.upsertProfile(profile)

        let appState = AppState(defaults: defaults)
        appState.cacheService = cache
        appState.familyZoneID = zoneID
        appState.currentProfile = profile

        // A remote device changes ONLY the payout policy. XP/logistics/name/
        // avatar are untouched, so the old field-subset change gate would have
        // skipped this update; the full-profile comparison must not.
        var policyChanged = profile
        policyChanged.payoutPolicy = .allOrNothing
        cache.upsertProfile(policyChanged)

        appState.updateCurrentProfileFromCache()

        #expect(appState.currentProfile?.payoutPolicy == .allOrNothing)

        // A second remote pass changes ONLY the payout day and custom avatar
        // image; both must also reach currentProfile.
        var avatarAndDayChanged = policyChanged
        avatarAndDayChanged.payoutDay = .friday
        avatarAndDayChanged.customAvatarImageData = Data([0xAA, 0xBB, 0xCC])
        cache.upsertProfile(avatarAndDayChanged)

        appState.updateCurrentProfileFromCache()

        #expect(appState.currentProfile?.payoutDay == .friday)
        #expect(appState.currentProfile?.customAvatarImageData == Data([0xAA, 0xBB, 0xCC]))
    }

    // MARK: - Post-Sign-Out Discovery

    /// A `MockCloudKitService` double exposing a configurable set of private and
    /// shared custom zones so `discoverExistingCloudState` can be driven down
    /// both its recoverable-family and fall-to-onboarding branches.
    private final class DiscoveryCloudKitService: MockCloudKitService {
        var privateZones: [CKRecordZone] = []
        var sharedZones: [CKRecordZone] = []
        var sharedZoneResponses: [[CKRecordZone]] = []
        private(set) var sharedZoneFetchCount = 0

        override func fetchPrivateZones() async throws -> [CKRecordZone] {
            privateZones
        }

        override func fetchSharedZones() async throws -> [CKRecordZone] {
            sharedZoneFetchCount += 1
            if !sharedZoneResponses.isEmpty {
                return sharedZoneResponses.removeFirst()
            }
            return sharedZones
        }
    }

    @Test
    func `signOutAndDiscover routes through discover and lands on detectedPreviousFamily`() async {
        let defaults = UserDefaults.ephemeral()
        // Simulate a signed-in session first so `signOutAndDiscover` demonstrably
        // wipes it during the transition.
        defaults.set(true, forKey: "session_hasActiveSession")

        let zoneID = CKRecordZone.ID(zoneName: "SharedHeroZone", ownerName: "HeroOwner")
        let familyID = CKRecord.ID(recordName: zoneID.zoneName, zoneID: zoneID)
        let family = Family(
            name: "Shared Guild",
            createdBy: CKRecord.ID(recordName: "gm1", zoneID: zoneID),
            id: familyID
        )
        let hero = Profile(
            displayName: "Recovered Hero",
            role: .hero,
            // The active hero carries the mock user's server-authenticated
            // identity so discovery's match against `currentUserRecordID` hits.
            iCloudUserID: CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID),
            family: CKRecord.Reference(recordID: familyID, action: .none),
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )

        let cloudKit = DiscoveryCloudKitService()
        cloudKit.seedMockRecords([family, hero])
        // No private owner zones — only a recoverable shared hero zone.
        cloudKit.sharedZones = [CKRecordZone(zoneID: zoneID)]

        let appState = AppState(defaults: defaults)
        await appState.signOutAndDiscover(cloudKit: cloudKit)

        guard case let .detectedPreviousFamily(family: detectedFamily,
                                               profile: detectedProfile,
                                               zoneID: detectedZoneID,
                                               isOwner: isOwner) = appState.authStatus
        else {
            #expect(Bool(false), "Expected .detectedPreviousFamily, got \(appState.authStatus)")
            return
        }
        // Discovery routed to the seeded hero + family in the shared zone.
        #expect(detectedFamily.id.recordName == "SharedHeroZone")
        #expect(detectedProfile.id.recordName == "hero1")
        #expect(detectedProfile.role == .hero)
        #expect(detectedZoneID == zoneID)
        #expect(isOwner == false)
        // The pre-existing signed-in session was cleared by sign-out.
        #expect(defaults.bool(forKey: "session_hasActiveSession") == false)
    }

    @Test
    func `shared discovery retries once within a bounded pass and ignores a later duplicate`() async {
        let defaults = UserDefaults.ephemeral()

        let zoneID = CKRecordZone.ID(zoneName: "BoundedSharedZone", ownerName: "SharedOwner")
        let familyID = CKRecord.ID(recordName: zoneID.zoneName, zoneID: zoneID)
        let family = Family(
            name: "Bounded Guild",
            createdBy: CKRecord.ID(recordName: "gm1", zoneID: zoneID),
            id: familyID
        )
        let hero = Profile(
            displayName: "Bounded Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID),
            family: CKRecord.Reference(recordID: familyID, action: .none),
            id: CKRecord.ID(recordName: "bounded-hero", zoneID: zoneID)
        )

        let cloudKit = DiscoveryCloudKitService()
        cloudKit.seedMockRecords([family, hero])
        cloudKit.sharedZoneResponses = [[], [], [CKRecordZone(zoneID: zoneID)]]

        let appState = AppState(defaults: defaults)
        await appState.discoverExistingCloudState(cloudKit: cloudKit)

        guard case .detectedPreviousFamily = appState.authStatus else {
            #expect(Bool(false), "Expected a family after the bounded shared-zone retry")
            return
        }
        #expect(cloudKit.sharedZoneFetchCount == 3)

        await appState.discoverExistingCloudState(cloudKit: cloudKit)
        #expect(cloudKit.sharedZoneFetchCount == 3)
    }

    @Test
    func `accepting a detected family activates the persisted session`() async {
        let defaults = UserDefaults.ephemeral()

        let zoneID = CKRecordZone.ID(zoneName: "AcceptZone", ownerName: "AcceptOwner")
        let familyID = CKRecord.ID(recordName: zoneID.zoneName, zoneID: zoneID)
        let family = Family(
            name: "Accepted Guild",
            createdBy: CKRecord.ID(recordName: "gm1", zoneID: zoneID),
            id: familyID
        )
        let hero = Profile(
            displayName: "Accepted Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID),
            family: CKRecord.Reference(recordID: familyID, action: .none),
            id: CKRecord.ID(recordName: "accepted-hero", zoneID: zoneID)
        )

        let cloudKit = DiscoveryCloudKitService()
        cloudKit.seedMockRecords([family, hero])
        cloudKit.sharedZones = [CKRecordZone(zoneID: zoneID)]

        let appState = AppState(defaults: defaults)
        await appState.discoverExistingCloudState(cloudKit: cloudKit)
        guard case let .detectedPreviousFamily(
            family: detectedFamily,
            profile: detectedProfile,
            zoneID: detectedZoneID,
            isOwner: detectedIsOwner
        ) = appState.authStatus else {
            #expect(Bool(false), "Expected a detected family before acceptance")
            return
        }
        await appState.acceptDetectedFamily(
            family: detectedFamily,
            profile: detectedProfile,
            zoneID: detectedZoneID,
            isOwner: detectedIsOwner,
            cloudKit: cloudKit
        )

        #expect(appState.authStatus == .authenticated)
        #expect(appState.family?.id == family.id)
        #expect(appState.currentProfile?.id == hero.id)
        #expect(appState.familyZoneID == zoneID)
        #expect(cloudKit.activeFamilyZoneID == zoneID)
        #expect(defaults.bool(forKey: "session_hasActiveSession"))
    }

    @Test
    func `identity mismatch falls back to cache before discovery`() async throws {
        let defaults = UserDefaults.ephemeral()

        let zoneID = CKRecordZone.ID(zoneName: "CacheFallbackZone", ownerName: "Owner")
        let familyID = CKRecord.ID(recordName: "cache-fallback-fam", zoneID: zoneID)
        let family = Family(
            name: "Cache Fallback Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: familyID
        )
        let profile = Profile(
            displayName: "Cache Fallback Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID),
            family: CKRecord.Reference(recordID: familyID, action: .none),
            id: CKRecord.ID(recordName: "cache-hero", zoneID: zoneID)
        )

        // Seed CloudKit with a profile whose server-stamped creator does NOT
        // match the current mock user so `requireServerAuthenticatedIdentity`
        // throws `identityMismatch` on the CloudKit fetch path.
        let cloudKit = MockCloudKitService()
        cloudKit.seedMockRecords([family, profile], creatorUserRecordName: "stale-creator")

        let cache = try CacheService(inMemory: true, defaults: defaults)
        cache.upsertFamily(family)
        cache.upsertProfile(profile)

        let appState = AppState(defaults: defaults)
        appState.cacheService = cache
        appState.saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: false)

        await appState.restoreSession(cloudKit: cloudKit)

        // With the cache-fallback fix, the app should restore from the local
        // cache rather than clearing state and falling through to discovery.
        #expect(appState.authStatus == .authenticated)
        #expect(appState.family?.id == family.id)
        #expect(appState.currentProfile?.id == profile.id)
        #expect(appState.familyZoneID == zoneID)
        #expect(defaults.bool(forKey: "session_hasActiveSession"))
    }

    @Test
    func `signOutAndDiscover falls through to onboarding when no recoverable family exists`() async {
        let defaults = UserDefaults.ephemeral()
        defaults.set(true, forKey: "session_hasActiveSession")

        // No private owner zones and no shared hero zones → nothing recoverable.
        let cloudKit = DiscoveryCloudKitService()

        let appState = AppState(defaults: defaults)
        await appState.signOutAndDiscover(cloudKit: cloudKit)

        #expect(appState.authStatus == .onboarding)
        // The signed-in session was cleared by sign-out.
        #expect(defaults.bool(forKey: "session_hasActiveSession") == false)
    }

    @Test
    func `clearSessionAndCloudKitScope clears CloudKit active scope and resets sync coordinator`() throws {
        let zoneID = CKRecordZone.ID(zoneName: "ScopeTestZone", ownerName: "Owner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true

        let defaults = UserDefaults.ephemeral()
        let appState = AppState(defaults: defaults)

        let cache = try CacheService(inMemory: true, defaults: defaults)
        appState.cacheService = cache

        let conflictResolver = CKSyncConflictResolver(cacheService: cache, appState: appState)
        let delegate = CKSyncEngineDelegateHandler(conflictResolver: conflictResolver, cacheService: cache, appState: appState)
        let coordinator = CKSyncEngineCoordinator(cloudKitService: cloudKit, delegateHandler: delegate, appState: appState, defaults: defaults)

        appState.clearSessionAndCloudKitScope(cloudKit: cloudKit, syncCoordinator: coordinator)

        #expect(cloudKit.activeFamilyZoneID == nil)
        #expect(cloudKit.activeIsOwner == false)
        #expect(appState.authStatus == .onboarding)
        #expect(appState.family == nil)
        #expect(appState.currentProfile == nil)
    }

    @Test
    func `rejectDetectedFamily clears CloudKit active scope and resets session`() async {
        let zoneID = CKRecordZone.ID(zoneName: "RejectZone", ownerName: "Owner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true

        let defaults = UserDefaults.ephemeral()
        let appState = AppState(defaults: defaults)
        let family = Family(name: "Reject Family", createdBy: CKRecord.ID(recordName: "owner"), id: CKRecord.ID(recordName: "RejectZone", zoneID: zoneID))
        let profile = Profile(
            displayName: "Reject Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "hero"),
            family: CKRecord.Reference(recordID: family.id, action: .none)
        )

        await appState.rejectDetectedFamily(family: family, profile: profile, zoneID: zoneID, isOwner: false, cloudKit: cloudKit)

        #expect(cloudKit.activeFamilyZoneID == nil)
        #expect(cloudKit.activeIsOwner == false)
        #expect(appState.authStatus == .onboarding)
    }

    @Test
    func `GM legacy family creator fallback recovers family via createdBy record`() async {
        let defaults = UserDefaults.ephemeral()
        defaults.set(true, forKey: "session_hasOnboarded")

        let zoneID = CKRecordZone.ID(zoneName: "LegacyGMZone", ownerName: "LegacyOwner")
        let familyID = CKRecord.ID(recordName: "legacy-gm-fam", zoneID: zoneID)
        let family = Family(
            name: "Mackin",
            createdBy: CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID),
            id: familyID
        )
        let gMProfile = Profile(
            displayName: "Legacy GM",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID),
            creatorUserRecordName: MockCloudKitService.mockUserRecordName,
            family: CKRecord.Reference(recordID: familyID, action: .none),
            id: CKRecord.ID(recordName: "gm-prof", zoneID: zoneID)
        )

        // Seed family with a stale server creator stamp but valid createdBy.
        // Profile is stamped correctly by the mock save.
        let cloudKit = DiscoveryCloudKitService()
        cloudKit.activeIsOwner = true
        cloudKit.seedMockRecords([family], creatorUserRecordName: "old-creator-id")
        cloudKit.seedMockRecords([gMProfile], creatorUserRecordName: MockCloudKitService.mockUserRecordName)
        cloudKit.privateZones = [CKRecordZone(zoneID: zoneID)]

        let appState = AppState(defaults: defaults)
        await appState.discoverExistingCloudState(cloudKit: cloudKit)

        guard case let .detectedPreviousFamily(family: detectedFamily,
                                               profile: detectedProfile,
                                               zoneID: detectedZoneID,
                                               isOwner: isOwner) = appState.authStatus
        else {
            #expect(Bool(false), "Expected .detectedPreviousFamily via createdBy fallback, got \(appState.authStatus)")
            return
        }
        #expect(detectedFamily.id.recordName == "legacy-gm-fam")
        #expect(detectedProfile.id.recordName == "gm-prof")
        #expect(detectedProfile.role == .guildMaster)
        #expect(detectedZoneID == zoneID)
        #expect(isOwner == true)
    }
}
