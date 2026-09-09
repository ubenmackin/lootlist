//
//  CloudKitServiceProtocolParsingTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData
import Testing

struct CloudKitServiceProtocolParsingTests {
    private let zoneID = CKRecordZone.ID(zoneName: "FamilyZone-Parsing", ownerName: CKCurrentUserDefaultName)

    private func id(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    // MARK: - Reverse lookup

    @Test
    func `recordType reverse lookup is total over all cases`() {
        for type in CachedRecordType.allCases {
            #expect(
                CachedRecordType.recordType(for: type.ckRecordType) == type,
                "Reverse lookup drops \(type)"
            )
        }
        #expect(CachedRecordType.recordType(for: "MysteryType") == nil)
    }

    @Test
    func `ckRecordTypes are unique across all cases`() {
        let recordTypes = CachedRecordType.allCases.map(\.ckRecordType)
        #expect(Set(recordTypes).count == CachedRecordType.allCases.count)
    }

    // MARK: - Exhaustive round-trip

    @Test
    func `every CachedRecordType round-trips through parse toCache toDomain`() {
        for type in CachedRecordType.allCases {
            let record = ExhaustiveCacheFixtures.fixtureRecord(for: type, zoneID: zoneID)
            let parsed = ParsedRecord.parse(record: record)
            switch parsed {
            case let .ignoredSystemRecord(recordType, _):
                Issue.record("Type \(type) parsed as ignoredSystemRecord (\(recordType)); expected a domain case.")
            case let .parseFailure(recordType, _):
                Issue.record("Type \(type) parsed as parseFailure (\(recordType)); expected a domain case.")
            default:
                break
            }
            #expect(parsed.cachedRecordType == type)
            #expect(parsed.recordName == record.recordID.recordName)
            ExhaustiveCacheFixtures.verifyParsed(parsed, expectedType: type, zoneID: zoneID)
        }
    }

    // MARK: - Root exception

    @Test
    func `familyCache root exception keeps empty familyRecordName`() {
        let familyCache = FamilyCache(from: ExhaustiveCacheFixtures.makeFamily(zoneID: zoneID))
        #expect(familyCache.recordName == ExhaustiveCacheFixtures.familyRecordName)
        let profileCache = ProfileCache(from: ExhaustiveCacheFixtures.makeProfile(zoneID: zoneID))
        ExhaustiveCacheFixtures.verifyFamilyRoot(familyCache: familyCache, scopedFamilyName: profileCache.familyRecordName)
        let restored = familyCache.toFamily(zoneID: zoneID)
        #expect(restored.id.recordName == ExhaustiveCacheFixtures.familyRecordName)
    }

    // MARK: - Silent-drop guard

    @Test
    func `unknown record types surface as parseFailure and shares as ignoredSystemRecord`() {
        let unknown = CKRecord(recordType: "MysteryType", recordID: id("mystery_1"))
        switch ParsedRecord.parse(record: unknown) {
        case let .parseFailure(recordType, recordName):
            #expect(recordType == "MysteryType")
            #expect(recordName == "mystery_1")
        default:
            Issue.record("Unknown record type must surface as parseFailure, not a silent drop.")
        }
        let share = CKRecord(recordType: "cloudkit.share", recordID: id("share_1"))
        switch ParsedRecord.parse(record: share) {
        case let .ignoredSystemRecord(recordType, recordName):
            #expect(recordType == "cloudkit.share")
            #expect(recordName == "share_1")
        default:
            Issue.record("Share record must surface as ignoredSystemRecord.")
        }
    }
}
