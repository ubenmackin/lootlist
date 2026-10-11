//
//  AuthenticationCoordinatorSharedZonePresenceTests.swift
//  LootList
//
//  Created by Ben Mackin on 10/11/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct SharedZonePresenceTests {
    @Test
    func `presence is listed when zone appears in shared listing`() async {
        let zoneID = CKRecordZone.ID(zoneName: "PresenceZone", ownerName: "PresenceOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.mockSharedZones = [CKRecordZone(zoneID: zoneID)]

        let presence = await AuthenticationCoordinator.sharedZoneStillListed(cloudKit: cloudKit, zoneID: zoneID)

        #expect(presence == .listed)
    }

    @Test
    func `presence is absent when listing succeeds without the zone`() async {
        let zoneID = CKRecordZone.ID(zoneName: "PresenceZone", ownerName: "PresenceOwner")
        let otherZoneID = CKRecordZone.ID(zoneName: "OtherZone", ownerName: "OtherOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.mockSharedZones = [CKRecordZone(zoneID: otherZoneID)]

        let presence = await AuthenticationCoordinator.sharedZoneStillListed(cloudKit: cloudKit, zoneID: zoneID)

        #expect(presence == .absent)
    }

    @Test
    func `presence is unknown when shared listing throws`() async {
        let zoneID = CKRecordZone.ID(zoneName: "PresenceZone", ownerName: "PresenceOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.mockSharedZonesError = CloudKitServiceError.networkUnavailable

        let presence = await AuthenticationCoordinator.sharedZoneStillListed(cloudKit: cloudKit, zoneID: zoneID)

        #expect(presence == .unknown)
    }

    @Test
    func `transient listed zoneNotFound restores from cache without revocation`() async throws {
        let defaults = UserDefaults.ephemeral()
        let zoneID = CKRecordZone.ID(zoneName: "TransientListedZone", ownerName: "Owner")
        let familyID = CKRecord.ID(recordName: "transient-listed-fam", zoneID: zoneID)
        let family = Family(name: "Transient Guild", creatorUserRecordName: "owner1", id: familyID)
        let profile = Profile(
            displayName: "Transient Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID),
            family: CKRecord.Reference(recordID: familyID, action: .none),
            id: CKRecord.ID(recordName: "transient-hero", zoneID: zoneID)
        )

        let cache = try CacheService(inMemory: true, defaults: defaults)
        await cache.upsertFamily(family)
        await cache.upsertProfile(profile)

        let appState = AppState(defaults: defaults)
        appState.cacheService = cache
        appState.authStatus = .restoringSession
        appState.saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: false)
        let revokedBefore = appState.familyAccessRevokedSignal

        let cloudKit = MockCloudKitService()
        cloudKit.fetchError = CloudKitServiceError.zoneNotFound
        cloudKit.mockSharedZones = [CKRecordZone(zoneID: zoneID)]

        await appState.restoreSession(cloudKit: cloudKit)

        #expect(appState.authStatus == .authenticated)
        #expect(appState.familyAccessRevokedSignal == revokedBefore)
        #expect(defaults.bool(forKey: "session_hasActiveSession") == true)
        #expect(appState.family?.id == family.id)
        #expect(appState.currentProfile?.id == profile.id)
    }

    @Test
    func `transient unlistable zoneNotFound restores from cache without revocation`() async throws {
        let defaults = UserDefaults.ephemeral()
        let zoneID = CKRecordZone.ID(zoneName: "TransientUnknownZone", ownerName: "Owner")
        let familyID = CKRecord.ID(recordName: "transient-unknown-fam", zoneID: zoneID)
        let family = Family(name: "Transient Guild", creatorUserRecordName: "owner1", id: familyID)
        let profile = Profile(
            displayName: "Transient Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID),
            family: CKRecord.Reference(recordID: familyID, action: .none),
            id: CKRecord.ID(recordName: "transient-hero", zoneID: zoneID)
        )

        let cache = try CacheService(inMemory: true, defaults: defaults)
        await cache.upsertFamily(family)
        await cache.upsertProfile(profile)

        let appState = AppState(defaults: defaults)
        appState.cacheService = cache
        appState.authStatus = .restoringSession
        appState.saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: false)
        let revokedBefore = appState.familyAccessRevokedSignal

        let cloudKit = MockCloudKitService()
        cloudKit.fetchError = CloudKitServiceError.zoneNotFound
        cloudKit.mockSharedZonesError = CloudKitServiceError.networkUnavailable

        await appState.restoreSession(cloudKit: cloudKit)

        #expect(appState.authStatus == .authenticated)
        #expect(appState.familyAccessRevokedSignal == revokedBefore)
        #expect(defaults.bool(forKey: "session_hasActiveSession") == true)
    }

    @Test
    func `transient listed zoneNotFound without cache waits offline`() async throws {
        let defaults = UserDefaults.ephemeral()
        let zoneID = CKRecordZone.ID(zoneName: "TransientEmptyZone", ownerName: "Owner")
        let familyID = CKRecord.ID(recordName: "transient-empty-fam", zoneID: zoneID)
        let family = Family(name: "Transient Guild", creatorUserRecordName: "owner1", id: familyID)
        let profile = Profile(
            displayName: "Transient Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID),
            family: CKRecord.Reference(recordID: familyID, action: .none),
            id: CKRecord.ID(recordName: "transient-hero", zoneID: zoneID)
        )

        let cache = try CacheService(inMemory: true, defaults: defaults)
        let appState = AppState(defaults: defaults)
        appState.cacheService = cache
        appState.authStatus = .restoringSession
        appState.saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: false)
        let revokedBefore = appState.familyAccessRevokedSignal

        let cloudKit = MockCloudKitService()
        cloudKit.fetchError = CloudKitServiceError.zoneNotFound
        cloudKit.mockSharedZones = [CKRecordZone(zoneID: zoneID)]

        await appState.restoreSession(cloudKit: cloudKit)

        #expect(appState.authStatus == .offlineEmptyCache)
        #expect(appState.familyAccessRevokedSignal == revokedBefore)
        #expect(defaults.bool(forKey: "session_hasActiveSession") == true)
    }

    @Test
    func `genuine absent zoneNotFound revokes purges and discovers`() async throws {
        let defaults = UserDefaults.ephemeral()
        let zoneID = CKRecordZone.ID(zoneName: "RevokedZone", ownerName: "Owner")
        let familyID = CKRecord.ID(recordName: "revoked-fam", zoneID: zoneID)
        let family = Family(name: "Revoked Guild", creatorUserRecordName: "owner1", id: familyID)
        let profile = Profile(
            displayName: "Revoked Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID),
            family: CKRecord.Reference(recordID: familyID, action: .none),
            id: CKRecord.ID(recordName: "revoked-hero", zoneID: zoneID)
        )

        let cache = try CacheService(inMemory: true, defaults: defaults)
        await cache.upsertFamily(family)
        await cache.upsertProfile(profile)

        let appState = AppState(defaults: defaults)
        appState.cacheService = cache
        appState.authStatus = .restoringSession
        appState.saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: false)
        let revokedBefore = appState.familyAccessRevokedSignal

        let cloudKit = MockCloudKitService()
        cloudKit.fetchError = CloudKitServiceError.zoneNotFound
        cloudKit.mockSharedZones = []

        await appState.restoreSession(cloudKit: cloudKit)

        #expect(appState.familyAccessRevokedSignal != revokedBefore)
        #expect(defaults.bool(forKey: "session_hasActiveSession") == false)
        #expect(appState.authStatus == .onboarding)
    }
}
