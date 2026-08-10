//
//  CloudKitService+Save.swift
//  LootList
//
//  Created by Ben Mackin on August 6, 2026.
//

import CloudKit
import Foundation

extension CloudKitService {
    func save<T: CloudKitRecord>(_ model: T,
                                 in zoneID: CKRecordZone.ID? = nil,
                                 using db: CKDatabase? = nil) async throws -> T
    {
        if isTestingOrMocking {
            let source = model.toRecord()
            let recordToSave = CKRecord(recordType: T.recordType, recordID: source.recordID)
            for key in source.allKeys() {
                recordToSave[key] = source[key]
            }
            mockRecords[source.recordID.recordName] = recordToSave
            return try T(record: recordToSave)
        }

        let zone = zoneID ?? resolvedZoneID
        guard let targetDB = db ?? activeFamilyDatabase else {
            throw CloudKitServiceError.accountUnavailable
        }

        let source = model.toRecord()
        let targetID: CKRecord.ID = {
            if source.recordID.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName {
                return source.recordID
            }
            return CKRecord.ID(recordName: source.recordID.recordName, zoneID: zone)
        }()

        let recordToSave: CKRecord
        do {
            recordToSave = try await targetDB.record(for: targetID)
        } catch let error as CKError where error.code == .unknownItem {
            recordToSave = CKRecord(recordType: T.recordType, recordID: targetID)
        } catch {
            throw error // Propagate network errors rather than silently creating duplicates
        }

        if T.recordType != Family.recordType {
            if let familyRef = source["family"] as? CKRecord.Reference {
                let parentID = CKRecord.ID(recordName: familyRef.recordID.recordName, zoneID: zone)
                recordToSave.setParent(parentID)
            } else if let parent = source.parent {
                let parentID = CKRecord.ID(recordName: parent.recordID.recordName, zoneID: zone)
                recordToSave.setParent(parentID)
            }
        }

        // Preserve server-side fields the model does not carry. `toRecord()`
        // writes a key only when the model manages it, and omits fields it does
        // not express (e.g. `Quest.name`/`descriptionText` before the backfill,
        // `LedgerEntry.location`, `QuestTemplate.specificDays` when empty), so
        // stripping every key the fresh model leaves nil would silently delete
        // concurrent server data written by another device. Clearing a field is
        // expressed explicitly: `toRecord()` writes `nil` for a managed field
        // (e.g. `Profile.avatarPresetID` when the avatar is removed), and that
        // nil write is applied below — exactly the mock path's semantics.
        for key in source.allKeys() {
            recordToSave[key] = source[key]
        }

        let dbLabel = targetDB == sharedDatabase ? "sharedDatabase" : "privateDatabase"
        let zoneName = zone.zoneName
        let ownerName = zone.ownerName
        let parentName = recordToSave.parent?.recordID.recordName ?? "none"
        logger.info("Save \(T.recordType, privacy: .public) id=\(recordToSave.recordID.recordName, privacy: .private) zone=\(zoneName, privacy: .private)")
        logger.info("owner=\(ownerName, privacy: .private) db=\(dbLabel, privacy: .public) parent=\(parentName, privacy: .private)")

        let saved: CKRecord
        do {
            saved = try await retrying {
                try await targetDB.save(recordToSave)
            }
        } catch {
            logger.error("Save failed for \(T.recordType, privacy: .public) (\(recordToSave.recordID.recordName, privacy: .private)): \(error, privacy: .private)")
            throw error
        }
        logger.info("Saved \(T.recordType, privacy: .public) (\(saved.recordID.recordName, privacy: .private))")
        return try T(record: saved)
    }

    func delete(_ recordID: CKRecord.ID,
                in zoneID: CKRecordZone.ID? = nil,
                using db: CKDatabase? = nil) async throws
    {
        if isTestingOrMocking {
            mockRecords.removeValue(forKey: recordID.recordName)
            return
        }

        let zone = zoneID ?? resolvedZoneID
        guard let targetDB = db ?? activeFamilyDatabase else {
            throw CloudKitServiceError.accountUnavailable
        }
        let targetID: CKRecord.ID = {
            if recordID.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName {
                return recordID
            }
            return CKRecord.ID(recordName: recordID.recordName, zoneID: zone)
        }()
        _ = try await retrying {
            try await targetDB.deleteRecord(withID: targetID)
        }
    }
}
