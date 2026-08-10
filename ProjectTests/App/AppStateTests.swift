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
        let cache = try CacheService(inMemory: true)
        cache.upsertFamily(family)
        cache.upsertProfile(profile)

        let appState = AppState()
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

        let cache = try CacheService(inMemory: true)
        cache.upsertFamily(familyA)
        cache.upsertFamily(familyB)
        cache.upsertFamily(familyC)
        cache.upsertProfile(profileA)
        cache.upsertProfile(profileB)
        cache.upsertProfile(profileC)

        let appState = AppState()
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

        let cache = try CacheService(inMemory: true)
        cache.upsertFamily(family)
        cache.upsertProfile(profile)

        let appState = AppState()
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
}
