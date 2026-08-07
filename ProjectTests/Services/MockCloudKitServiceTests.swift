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
    func `mock share URL returns a valid URL on happy path`() async throws {
        let mock = MockCloudKitService()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let rootID = CKRecord.ID(recordName: "root", zoneID: zoneID)

        let url = try await mock.fetchOrCreateShareURL(in: zoneID, rootRecordID: rootID)

        #expect(url.scheme == "https")
        #expect(url.host == "www.icloud.com")
    }

    @Test
    func `cloud kit service returns a valid share URL on happy path`() async throws {
        let cloudKit = MockCloudKitService()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let rootID = CKRecord.ID(recordName: "root", zoneID: zoneID)

        let url = try await cloudKit.fetchOrCreateShareURL(in: zoneID, rootRecordID: rootID)

        #expect(url.scheme == "https")
        #expect(url.host == "www.icloud.com")
    }
}
