//
//  MockCloudKitServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 2026-08-04
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct MockCloudKitServiceTests {
    @Test
    func `mock share title round-trips the hero role token`() async throws {
        let mock = MockCloudKitService()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let rootID = CKRecord.ID(recordName: "root", zoneID: zoneID)

        let share = try await mock.fetchOrCreateShare(for: rootID, role: .hero)

        let title = share[CKShare.SystemFieldKey.title] as? String
        #expect(UserRole.fromShareTitle(title) == .hero)
        #expect(title?.hasSuffix(UserRole.hero.shareTitleSuffix) == true)
    }

    @Test
    func `cloud kit service mints distinct role-titled shares on happy path`() async throws {
        let cloudKit = MockCloudKitService()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let rootID = CKRecord.ID(recordName: "root", zoneID: zoneID)

        let rangerShare = try await cloudKit.fetchOrCreateShare(for: rootID, role: .ranger)
        let heroShare = try await cloudKit.fetchOrCreateShare(for: rootID, role: .hero)

        let rangerTitle = rangerShare[CKShare.SystemFieldKey.title] as? String
        let heroTitle = heroShare[CKShare.SystemFieldKey.title] as? String
        #expect(UserRole.fromShareTitle(rangerTitle) == .ranger)
        #expect(UserRole.fromShareTitle(heroTitle) == .hero)
        #expect(rangerTitle != heroTitle)
    }

    @Test
    func `removeParticipant by identity revokes from both hero and ranger shares`() async throws {
        let mock = MockCloudKitService()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let rootID = CKRecord.ID(recordName: "root", zoneID: zoneID)

        // A family root carries two coexisting role shares; the same identity
        // ("memberKid") can be invited onto both. CloudKit cannot fabricate
        // `CKShare.Participant` instances in unit tests, so the mock seeds its
        // simulated membership with the identity keys the sharing service uses.
        let heroShare = try await mock.simulateParticipation(key: "record:memberKid", rootRecordID: rootID, role: .hero)
        let rangerShare = try await mock.simulateParticipation(key: "record:memberKid", rootRecordID: rootID, role: .ranger)
        // An unrelated member on the Ranger share must survive the revocation.
        try await mock.simulateParticipation(key: "record:otherParent", rootRecordID: rootID, role: .ranger)

        let heroShareID = heroShare.recordID
        let rangerShareID = rangerShare.recordID
        #expect(mock.mockShareMemberships[heroShareID]?.contains("record:memberKid") == true)
        #expect(mock.mockShareMemberships[rangerShareID]?.contains("record:memberKid") == true)
        #expect(mock.revokedShareIDs.isEmpty)

        try await mock.removeParticipant(iCloudUserRecordName: "memberKid", from: rootID)

        // Revocation must span every role share — removing from only the first
        // match would leave the member with live access through the second.
        #expect(mock.revokedShareIDs.count == 2)
        #expect(Set(mock.revokedShareIDs) == [heroShareID, rangerShareID])
        #expect(mock.mockShareMemberships[heroShareID]?.contains("record:memberKid") == false)
        #expect(mock.mockShareMemberships[rangerShareID]?.contains("record:memberKid") == false)
        // Only the revoked identity was stripped; the other member is untouched.
        #expect(mock.mockShareMemberships[rangerShareID]?.contains("record:otherParent") == true)
    }

    // No-match revocations must never be silent no-ops: `MockCloudKitService`
    // throws `shareFailed` on both overloads when no role share contains the
    // passed identity. The object overload's unmatchable path cannot be driven
    // from a unit test (`CKShareParticipant` and `CKUserIdentity` have no
    // usable public initializer — `init NS_UNAVAILABLE` in the CloudKit
    // headers; participants are server-minted via the share's `participants`
    // property), so that throw is verified by code review. The record-name
    // overload's no-match throw is what the Invitations-panel revocation test
    // relies on: it reproduces the propagation race that the security fix
    // reports through `FamilyDashboardViewModel.loadError`.
}
