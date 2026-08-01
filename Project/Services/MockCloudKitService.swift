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

    var activeFamilyZoneID: CKRecordZone.ID?
    var activeIsOwner: Bool = true
    var mockRecords: [CKRecord.ID: CKRecord] = [:]

    func database(isOwner: Bool) -> CKDatabase {
        if isOwner {
            Self.defaultContainer.privateCloudDatabase
        } else {
            Self.defaultContainer.sharedCloudDatabase
        }
    }

    func activeFamilyDatabase() -> CKDatabase {
        database(isOwner: activeIsOwner)
    }

    func save(_ record: CKRecord, database _: CKDatabase) async throws {
        mockRecords[record.recordID] = record
    }

    func delete(_ recordID: CKRecord.ID, database _: CKDatabase) async throws {
        mockRecords.removeValue(forKey: recordID)
    }

    func fetch(recordID: CKRecord.ID, database _: CKDatabase) async throws -> CKRecord {
        guard let record = mockRecords[recordID] else {
            throw CloudKitServiceError.notFound(recordID.recordName)
        }
        return record
    }

    func query(recordType: String, predicate _: NSPredicate, database _: CKDatabase) async throws -> [CKRecord] {
        mockRecords.values.filter { $0.recordType == recordType }
    }

    func createShare(for record: CKRecord, database _: CKDatabase) async throws -> (CKShare, CKContainer) {
        let share = CKShare(rootRecord: record)
        return (share, Self.defaultContainer)
    }

    func fetchOrCreateShareURL(for _: CKRecordZone.ID, database _: CKDatabase) async throws -> URL {
        URL(string: "https://www.icloud.com/share/mock")!
    }

    func acceptShare(metadata _: CKShare.Metadata) async throws {}

    func processAbandonedZonesQueue(appState _: AppState) async {}
}
