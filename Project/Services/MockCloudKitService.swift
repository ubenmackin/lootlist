//
//  MockCloudKitService.swift
//  LootList
//
//  Created by Ben Mackin on 7/31/26.
//

import CloudKit
import Foundation

@MainActor
final class MockCloudKitService: CloudKitServiceProtocol {
    static var defaultContainer: CKContainer {
        CKContainer.default()
    }

    var container: CKContainer {
        Self.defaultContainer
    }

    var activeFamilyZoneID: CKRecordZone.ID?
    var activeIsOwner: Bool = true
    var mockRecords: [CKRecord.ID: CKRecord] = [:]

    var resolvedZoneID: CKRecordZone.ID {
        activeFamilyZoneID ?? CKRecordZone.default().zoneID
    }

    var database: CKDatabase {
        database(isOwner: activeIsOwner)
    }

    var privateDatabase: CKDatabase {
        Self.defaultContainer.privateCloudDatabase
    }

    var sharedDatabase: CKDatabase {
        Self.defaultContainer.sharedCloudDatabase
    }

    var activeFamilyDatabase: CKDatabase {
        database(isOwner: activeIsOwner)
    }

    func database(isOwner: Bool) -> CKDatabase {
        if isOwner {
            Self.defaultContainer.privateCloudDatabase
        } else {
            Self.defaultContainer.sharedCloudDatabase
        }
    }

    func save<T: CloudKitRecord>(_ entity: T, in _: CKRecordZone.ID?, using _: CKDatabase?) async throws -> T {
        let record = entity.toRecord()
        mockRecords[record.recordID] = record
        return entity
    }

    func fetch<T: CloudKitRecord>(_ type: T.Type, id: CKRecord.ID, using _: CKDatabase?) async throws -> T {
        _ = type
        guard let record = mockRecords[id] else {
            throw CloudKitServiceError.notFound(id.recordName)
        }
        return try T(record: record)
    }

    func query<T: CloudKitRecord>(_: T.Type, predicate: NSPredicate, in zoneID: CKRecordZone.ID?, sortDescriptors: [NSSortDescriptor]?, using _: CKDatabase?) async throws -> [T] {
        var matching = mockRecords.values.filter { $0.recordType == T.recordType }
        if let zoneID {
            matching = matching.filter { $0.recordID.zoneID == zoneID }
        }
        if predicate != NSPredicate(value: true) {
            matching = matching.filter { predicate.evaluate(with: $0) }
        }
        var results = try matching.map { try T(record: $0) }
        if let sortDescriptors, !sortDescriptors.isEmpty {
            let nsArray = (results as NSArray).sortedArray(using: sortDescriptors)
            if let sortedResults = nsArray as? [T] {
                results = sortedResults
            }
        }
        return results
    }

    func delete(_ recordID: CKRecord.ID, in _: CKRecordZone.ID?, using _: CKDatabase?) async throws {
        mockRecords.removeValue(forKey: recordID)
    }

    func delete(_ entity: some CloudKitRecord, using _: CKDatabase?) async throws {
        let record = entity.toRecord()
        mockRecords.removeValue(forKey: record.recordID)
    }

    func ensureZoneExists(_: CKRecordZone.ID) async throws {}

    func fetchZoneChanges(in _: CKRecordZone.ID?, since _: CKServerChangeToken?, using _: CKDatabase?) async throws -> ZoneChangesResult {
        ZoneChangesResult(
            changedRecords: Array(mockRecords.values),
            deletedRecordIDs: [],
            newToken: nil,
            moreComing: false
        )
    }

    func createShare(for rootRecordID: CKRecord.ID) async throws -> CKShare {
        let root = mockRecords[rootRecordID] ?? CKRecord(recordType: Family.recordType, recordID: rootRecordID)
        return CKShare(rootRecord: root)
    }

    func fetchOrCreateShareURL(in _: CKRecordZone.ID, rootRecordID _: CKRecord.ID) async throws -> URL {
        URL(string: "https://www.icloud.com/share/mock")!
    }

    func acceptShare(metadata _: CKShare.Metadata) async throws {}

    func processAbandonedZonesQueue(appState _: AppState) async {}

    func currentUserRecordID() async throws -> CKRecord.ID {
        CKRecord.ID(recordName: "mockUser", zoneID: resolvedZoneID)
    }

    func fetchPrivateZones() async throws -> [CKRecordZone] {
        []
    }

    func fetchSharedZones() async throws -> [CKRecordZone] {
        []
    }

    func deleteZone(_ zoneID: CKRecordZone.ID) async throws {
        _ = zoneID
    }
}
