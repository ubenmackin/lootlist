//
//  CloudKitServiceProtocol.swift
//  LootList
//
//  Created by Ben Mackin on 7/31/26.
//

import CloudKit
import Foundation

@MainActor
protocol CloudKitServiceProtocol: AnyObject, Sendable {
    static var defaultContainer: CKContainer { get }
    var activeFamilyZoneID: CKRecordZone.ID? { get set }
    var activeIsOwner: Bool { get set }

    func database(isOwner: Bool) -> CKDatabase
    func activeFamilyDatabase() -> CKDatabase

    func save(_ record: CKRecord, database: CKDatabase) async throws
    func delete(_ recordID: CKRecord.ID, database: CKDatabase) async throws
    func fetch(recordID: CKRecord.ID, database: CKDatabase) async throws -> CKRecord
    func query(recordType: String, predicate: NSPredicate, database: CKDatabase) async throws -> [CKRecord]

    func createShare(for record: CKRecord, database: CKDatabase) async throws -> (CKShare, CKContainer)
    func fetchOrCreateShareURL(for zoneID: CKRecordZone.ID, database: CKDatabase) async throws -> URL
    func acceptShare(metadata: CKShare.Metadata) async throws

    func processAbandonedZonesQueue(appState: AppState) async
}
