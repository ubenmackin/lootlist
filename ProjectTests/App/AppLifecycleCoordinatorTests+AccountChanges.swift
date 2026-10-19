//
//  AppLifecycleCoordinatorTests+AccountChanges.swift
//  LootList
//
//  Created by Ben Mackin on 10/18/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
extension AppLifecycleCoordinatorTests {
    // MARK: - Account Change Signal Handling

    @Test
    func `account change flap with matching user record ID preserves authenticated session`() async throws {
        let defaults = UserDefaults.ephemeral()
        let appState = AppState(defaults: defaults)
        let zoneID = CKRecordZone.ID(zoneName: "FlapZone", ownerName: "Owner")
        let (family, profile) = makeFamilyAndProfile(zoneID: zoneID)
        appState.family = family
        appState.currentProfile = profile
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.authStatus = .authenticated

        let cloudKit = MockCloudKitService()
        cloudKit.mockCurrentUserRecordID = CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID)
        let sync = CountingSyncCoordinator()
        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: sync, defaults: defaults)

        await lifecycle.handleAccountChangeSignal()

        #expect(appState.authStatus == .authenticated)
        #expect(appState.currentProfile?.id == profile.id)
        #expect(appState.family?.id == family.id)
    }

    @Test
    func `account change flap during restoringSession is deferred without state change`() async throws {
        let defaults = UserDefaults.ephemeral()
        let appState = AppState(defaults: defaults)
        appState.authStatus = .restoringSession

        let cloudKit = MockCloudKitService()
        let sync = CountingSyncCoordinator()
        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: sync, defaults: defaults)

        await lifecycle.handleAccountChangeSignal()

        #expect(appState.authStatus == .restoringSession)
    }

    @Test
    func `account change check network failure preserves local-first authenticated session`() async throws {
        let defaults = UserDefaults.ephemeral()
        let appState = AppState(defaults: defaults)
        let zoneID = CKRecordZone.ID(zoneName: "NetworkErrZone", ownerName: "Owner")
        let (family, profile) = makeFamilyAndProfile(zoneID: zoneID)
        appState.family = family
        appState.currentProfile = profile
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.authStatus = .authenticated

        let cloudKit = MockCloudKitService()
        cloudKit.mockCurrentUserRecordIDError = CloudKitServiceError.networkUnavailable
        let sync = CountingSyncCoordinator()
        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: sync, defaults: defaults)

        await lifecycle.handleAccountChangeSignal()

        #expect(appState.authStatus == .authenticated)
        #expect(appState.currentProfile?.id == profile.id)
    }

    @Test
    func `genuine account change with different user record ID triggers signOutAndDiscover`() async throws {
        let defaults = UserDefaults.ephemeral()
        let appState = AppState(defaults: defaults)
        let zoneID = CKRecordZone.ID(zoneName: "GenuineChangeZone", ownerName: "Owner")
        let (family, profile) = makeFamilyAndProfile(zoneID: zoneID)
        appState.saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: true)
        appState.family = family
        appState.currentProfile = profile
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.authStatus = .authenticated

        let cloudKit = MockCloudKitService()
        cloudKit.mockCurrentUserRecordID = CKRecord.ID(recordName: "differentUser456", zoneID: zoneID)
        let sync = CountingSyncCoordinator()
        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: sync, defaults: defaults)

        await lifecycle.handleAccountChangeSignal()

        // Discovery completes and sets .onboarding (no families found for different user), never left in .checkingCloudData
        #expect(appState.currentProfile == nil)
        #expect(appState.family == nil)
        #expect(appState.authStatus == .onboarding)
    }
}
