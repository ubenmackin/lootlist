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
        CKContainer(identifier: "iCloud.com.volcrypt.lootlist")
    }

    /// The fixed current iCloud user the mock reports via `currentUserRecordID()`.
    static let mockUserRecordName = "mockUser"

    var container: CKContainer {
        Self.defaultContainer
    }

    var activeFamilyZoneID: CKRecordZone.ID?
    var activeIsOwner: Bool = true
    var mockRecords: [CKRecord.ID: CKRecord] = [:]
    var fetchError: Error?

    /// Emulates CloudKit's server-side creator stamp. The SDK allows only the
    /// server to write `CKRecord.creatorUserRecordID`, so the mock mirrors that
    /// read-only system field in a registry and applies it onto decoded models.
    var recordCreators: [CKRecord.ID: String] = [:]

    var resolvedZoneID: CKRecordZone.ID {
        activeFamilyZoneID ?? CKRecordZone.default().zoneID
    }

    /// Protocol conformance stub (see `CloudKitServiceProtocol.seedMockRecords`):
    /// seeds records into the mock store with the default server-stamped
    /// creator — the mock's fixed current user ("mockUser").
    func seedMockRecords(_ models: [any CloudKitRecord]) {
        seedMockRecords(models, creatorUserRecordName: Self.mockUserRecordName)
    }

    /// Emulates CloudKit's server-side creator stamp for a specific caller. An
    /// explicit `creatorUserRecordName` stamps the record as authored by that
    /// iCloud user; passing nil leaves the registry unset so the record decodes
    /// with a nil `creatorUserRecordName` (a legacy family with no creator
    /// anchor). Callers that want the default stamp (the mock's fixed current
    /// user, "mockUser") should use the single-argument `seedMockRecords(_:)`.
    /// Records written via `save` are always stamped with the acting user.
    func seedMockRecords(_ models: [any CloudKitRecord], creatorUserRecordName: String?) {
        for model in models {
            let record = model.toRecord()
            mockRecords[record.recordID] = record
            // `nil` subscript removes the key, leaving a legacy record with no
            // server-stamped creator.
            recordCreators[record.recordID] = creatorUserRecordName
        }
    }

    var database: CKDatabase {
        container.privateCloudDatabase
    }

    var privateDatabase: CKDatabase {
        container.privateCloudDatabase
    }

    var sharedDatabase: CKDatabase {
        container.sharedCloudDatabase
    }

    var activeFamilyDatabase: CKDatabase {
        container.privateCloudDatabase
    }

    func database(isOwner: Bool) -> CKDatabase {
        isOwner ? privateDatabase : sharedDatabase
    }

    func save<T: CloudKitRecord>(_ entity: T, in _: CKRecordZone.ID?, using _: CKDatabase?) async throws -> T {
        let record = entity.toRecord()
        // Emulate the server: stamp the creator only on creation, before
        // persisting and re-decoding (mirrors the real `CloudKitService.save`'s
        // `return try T(record: saved)`). A later edit by a different user must
        // not overwrite or clear the original server-stamped creator, so the
        // existing stamp (if any) is left untouched.
        if recordCreators[record.recordID] == nil {
            recordCreators[record.recordID] = await (try? currentUserRecordID())?.recordName
        }
        mockRecords[record.recordID] = record
        let decoded = try T(record: record)
        return applyingCreatorStamp(for: record.recordID, on: decoded)
    }

    func fetch<T: CloudKitRecord>(_ type: T.Type, id: CKRecord.ID, using _: CKDatabase?) async throws -> T {
        if let fetchError {
            throw fetchError
        }
        _ = type
        guard let record = mockRecords[id] else {
            throw CloudKitServiceError.notFound(id.recordName)
        }
        let decoded = try T(record: record)
        return applyingCreatorStamp(for: id, on: decoded)
    }

    func query<T: CloudKitRecord>(_: T.Type, predicate: NSPredicate, in zoneID: CKRecordZone.ID?, sortDescriptors: [NSSortDescriptor]?, using _: CKDatabase?) async throws -> [T] {
        var matching = mockRecords.values.filter { $0.recordType == T.recordType }
        if let zoneID {
            matching = matching.filter { $0.recordID.zoneID == zoneID }
        }
        if predicate != NSPredicate(value: true) {
            matching = matching.filter { predicate.evaluate(with: $0) }
        }
        var results = try matching.map { record -> T in
            let decoded = try T(record: record)
            return applyingCreatorStamp(for: record.recordID, on: decoded)
        }
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
        guard let url = URL(string: "https://www.icloud.com/share/mock") else {
            throw CloudKitServiceError.invalidArguments("Malformed mock share URL")
        }
        return url
    }

    func acceptShare(metadata _: CKShare.Metadata) async throws {}

    func processAbandonedZonesQueue(appState _: AppState) async {}

    func currentUserRecordID() async throws -> CKRecord.ID {
        CKRecord.ID(recordName: Self.mockUserRecordName, zoneID: resolvedZoneID)
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

    /// Applies the emulated server creator stamp onto a decoded model. Only the
    /// `Family` model carries the creator anchor; all other record types are
    /// returned untouched. The registry is authoritative because CloudKit owns
    /// the creator field — a locally-authored value cannot override the stamp.
    private func applyingCreatorStamp<T: CloudKitRecord>(for recordID: CKRecord.ID, on result: T) -> T {
        guard var family = result as? Family, let creator = recordCreators[recordID] else {
            return result
        }
        family.creatorUserRecordName = creator
        // `result` is already a Family (proven by the guard above), so the
        // optional cast back up to `T` never fails; the fallback exists only
        // to keep the code free of forced casts.
        return family as? T ?? result
    }
}
