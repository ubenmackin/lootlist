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
}
