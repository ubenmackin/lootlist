//
//  CacheConversionsTests+SystemFields.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData
import Testing

extension CacheConversionsTests {
    // MARK: - Exhaustiveness round-trip (13 types)

    @Test
    func `all 13 cache types preserve changeTag and encodedSystemFields through toXxx and toDomain`() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "_a1b2c3d4")
        for type in CachedRecordType.allCases {
            ExhaustiveCacheFixtures.verifyDirect(for: type, zoneID: zoneID)
        }
    }
}
