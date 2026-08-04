//
//  CloudKitServiceProtocol.swift
//  LootList
//
//  Created by Ben Mackin on 7/31/26.
//

import CloudKit
import Foundation

struct ZoneChangesResult: Sendable {
    let changedRecords: [CKRecord]
    let deletedRecordIDs: [(recordID: CKRecord.ID, recordType: String)]
    let newToken: CKServerChangeToken?
    let moreComing: Bool
}

@MainActor
protocol CloudKitServiceProtocol: AnyObject, Sendable {
    static var defaultContainer: CKContainer { get }
    var container: CKContainer { get }

    var activeFamilyZoneID: CKRecordZone.ID? { get set }
    var activeIsOwner: Bool { get set }
    var resolvedZoneID: CKRecordZone.ID { get }

    var database: CKDatabase { get }
    var privateDatabase: CKDatabase { get }
    var sharedDatabase: CKDatabase { get }
    var activeFamilyDatabase: CKDatabase { get }

    func database(isOwner: Bool) -> CKDatabase

    func save<T: CloudKitRecord>(_ entity: T, in zoneID: CKRecordZone.ID?, using db: CKDatabase?) async throws -> T
    func fetch<T: CloudKitRecord>(_ type: T.Type, id: CKRecord.ID, using db: CKDatabase?) async throws -> T
    func query<T: CloudKitRecord>(_ type: T.Type, predicate: NSPredicate, in zoneID: CKRecordZone.ID?, sortDescriptors: [NSSortDescriptor]?, using db: CKDatabase?) async throws
        -> [T]
    func delete(_ recordID: CKRecord.ID, in zoneID: CKRecordZone.ID?, using db: CKDatabase?) async throws
    func delete(_ entity: some CloudKitRecord, using db: CKDatabase?) async throws

    func ensureZoneExists(_ zoneID: CKRecordZone.ID) async throws
    func fetchZoneChanges(in zoneID: CKRecordZone.ID?, since token: CKServerChangeToken?, using db: CKDatabase?) async throws -> ZoneChangesResult

    func createShare(for rootRecordID: CKRecord.ID) async throws -> CKShare
    func fetchOrCreateShareURL(in zoneID: CKRecordZone.ID, rootRecordID: CKRecord.ID) async throws -> URL
    func acceptShare(metadata: CKShare.Metadata) async throws

    func processAbandonedZonesQueue(appState: AppState) async
    func currentUserRecordID() async throws -> CKRecord.ID
    func fetchPrivateZones() async throws -> [CKRecordZone]
    func fetchSharedZones() async throws -> [CKRecordZone]
    func deleteZone(_ zoneID: CKRecordZone.ID) async throws
}

extension CloudKitServiceProtocol {
    func save<T: CloudKitRecord>(
        _ entity: T,
        in zoneID: CKRecordZone.ID? = nil,
        using db: CKDatabase? = nil
    ) async throws -> T {
        try await save(entity, in: zoneID, using: db)
    }

    func fetch<T: CloudKitRecord>(
        _ type: T.Type,
        id: CKRecord.ID,
        using db: CKDatabase? = nil
    ) async throws -> T {
        try await fetch(type, id: id, using: db)
    }

    func query<T: CloudKitRecord>(
        _ type: T.Type,
        predicate: NSPredicate = NSPredicate(value: true),
        in zoneID: CKRecordZone.ID? = nil,
        sortDescriptors: [NSSortDescriptor]? = nil,
        using db: CKDatabase? = nil
    ) async throws -> [T] {
        try await query(type, predicate: predicate, in: zoneID, sortDescriptors: sortDescriptors, using: db)
    }

    func delete(_ recordID: CKRecord.ID, in zoneID: CKRecordZone.ID? = nil, using db: CKDatabase? = nil) async throws {
        try await delete(recordID, in: zoneID, using: db)
    }

    func delete(_ entity: some CloudKitRecord, using db: CKDatabase? = nil) async throws {
        try await delete(entity, using: db)
    }

    func fetchZoneChanges(
        in zoneID: CKRecordZone.ID? = nil,
        since token: CKServerChangeToken? = nil,
        using db: CKDatabase? = nil
    ) async throws -> ZoneChangesResult {
        try await fetchZoneChanges(in: zoneID, since: token, using: db)
    }
}
