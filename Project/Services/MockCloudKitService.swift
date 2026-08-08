//
//  MockCloudKitService.swift
//  LootList
//
//  Created by Ben Mackin on 7/31/26.
//

import CloudKit
import Foundation

@MainActor
class MockCloudKitService: CloudKitServiceProtocol {
    /// The fixed current iCloud user the mock reports via `currentUserRecordID()`.
    static let mockUserRecordName = "mockUser"

    private static let containerInstance: CKContainer = .init(identifier: "iCloud.com.volcrypt.lootlist")

    static var defaultContainer: CKContainer {
        containerInstance
    }

    var container: CKContainer {
        Self.defaultContainer
    }

    var activeFamilyZoneID: CKRecordZone.ID?
    var activeIsOwner: Bool = true
    var mockRecords: [CKRecord.ID: CKRecord] = [:]
    var fetchError: Error?
    /// Optional per-test injection: when set, `save` throws this error after
    /// persisting the record's `CKRecord` form into the mock store. Mirrors
    /// `fetchError` so tests can drive a save-time conflict (e.g.
    /// `CloudKitServiceError.serverRecordChanged`) and still observe a
    /// subsequent authoritative `fetch` against the seeded `mockRecords`.
    var saveError: Error?

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

    var database: CKDatabase? {
        nil
    }

    var privateDatabase: CKDatabase? {
        nil
    }

    var sharedDatabase: CKDatabase? {
        nil
    }

    var activeFamilyDatabase: CKDatabase? {
        nil
    }

    func database(isOwner _: Bool) -> CKDatabase? {
        nil
    }

    func save<T: CloudKitRecord>(_ entity: T, in _: CKRecordZone.ID?, using _: CKDatabase?) async throws -> T {
        // Per-test save-time conflict injection (mirrors `fetchError` on the
        // fetch path). Throw BEFORE persisting so a previously-seeded
        // authoritative record in `mockRecords` survives — exactly the
        // state a real CloudKit `serverRecordChanged` leaves behind
        // (another device's record lives on, our rejected write never landed),
        // which lets the rollback path's re-`fetch` retrieve that authoritative
        // value rather than the optimistic state we attempted to push.
        if let saveError {
            throw saveError
        }
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

    func query<T: CloudKitRecord>(_: T.Type, predicate: NSPredicate, in _: CKRecordZone.ID?, sortDescriptors: [NSSortDescriptor]?, using _: CKDatabase?) async throws -> [T] {
        var matching = Array(mockRecords.values.filter { $0.recordType == T.recordType })
        if predicate != NSPredicate(value: true) {
            matching = matching.filter { predicate.evaluate(with: $0) }
        }
        if let sortDescriptors, !sortDescriptors.isEmpty {
            let nsArray = (matching as NSArray).sortedArray(using: sortDescriptors)
            if let sortedMatching = nsArray as? [CKRecord] {
                matching = sortedMatching
            }
        }
        return try matching.map { record -> T in
            let decoded = try T(record: record)
            return applyingCreatorStamp(for: record.recordID, on: decoded)
        }
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
        let parsed: [ParsedRecord] = mockRecords.values.compactMap { record in
            do {
                switch record.recordType {
                case Family.recordType: return try .family(Family(record: record))
                case Profile.recordType: return try .profile(Profile(record: record))
                case Quest.recordType: return try .quest(Quest(record: record))
                case QuestTemplate.recordType: return try .questTemplate(QuestTemplate(record: record))
                case QuestCompletion.recordType: return try .questCompletion(QuestCompletion(record: record))
                case LedgerEntry.recordType: return try .ledgerEntry(LedgerEntry(record: record))
                case AllowancePeriod.recordType: return try .allowancePeriod(AllowancePeriod(record: record))
                case Achievement.recordType: return try .achievement(Achievement(record: record))
                case ProfileAchievement.recordType: return try .profileAchievement(ProfileAchievement(record: record))
                case NotificationPreference.recordType: return try .notificationPreference(NotificationPreference(record: record))
                default: return .parseFailure(recordType: record.recordType, recordName: record.recordID.recordName)
                }
            } catch {
                return .parseFailure(recordType: record.recordType, recordName: record.recordID.recordName)
            }
        }
        return ZoneChangesResult(
            changedRecords: parsed,
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

    func fetchShareMetadata(for _: URL) async throws -> CKShare.Metadata {
        throw CloudKitServiceError.notFound("Mock share metadata not configured")
    }

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
