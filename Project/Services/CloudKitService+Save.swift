//
//  CloudKitService+Save.swift
//  LootList
//
//  Created by Ben Mackin on August 6, 2026.
//

import CloudKit
import Foundation

extension CloudKitService {
    func claimRewardEvent(_ event: RewardEvent,
                          in zoneID: CKRecordZone.ID? = nil,
                          using db: CKDatabase? = nil) async throws -> Bool
    {
        guard let zone = zoneID ?? activeFamilyZoneID else {
            throw CloudKitServiceError.invalidArguments("No zoneID provided and no activeFamilyZoneID available")
        }
        guard let targetDB = db ?? activeFamilyDatabase else {
            throw CloudKitServiceError.accountUnavailable
        }

        let source = event.toRecord()
        let targetID = source.recordID.zoneID.zoneName == CKRecordZone.default().zoneID.zoneName
            ? CKRecord.ID(recordName: source.recordID.recordName, zoneID: zone)
            : source.recordID
        let record = CKRecord(recordType: RewardEvent.recordType, recordID: targetID)
        for key in source.allKeys() {
            record[key] = source[key]
        }
        record.setParent(CKRecord.ID(recordName: event.family.recordID.recordName, zoneID: zone))

        do {
            let (saveResults, _) = try await targetDB.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            if let result = saveResults[record.recordID] {
                switch result {
                case .success:
                    return true
                case let .failure(error):
                    if let ckError = error as? CKError,
                       ckError.code == .serverRecordChanged || ckError.code == .constraintViolation
                    {
                        return false
                    }
                    throw error
                }
            }
            return true
        } catch let ckError as CKError where ckError.code == .serverRecordChanged || ckError.code == .constraintViolation {
            return false
        }
    }

    func save<T: CloudKitRecord>(_ model: T,
                                 in zoneID: CKRecordZone.ID? = nil,
                                 using db: CKDatabase? = nil) async throws -> T
    {
        guard let zone = zoneID ?? activeFamilyZoneID else {
            logger.error("CloudKitService.save rejected: no zoneID provided and no activeFamilyZoneID available")
            throw CloudKitServiceError.invalidArguments("No zoneID provided and no activeFamilyZoneID available")
        }
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

        // Overlay all non-nil fields from the source model onto the fetched record.
        for key in source.allKeys() {
            recordToSave[key] = source[key]
        }

        // Explicitly clear any managed optional fields omitted (nil) from the source model.
        // Unmanaged / future schema fields on the server record remain untouched.
        let sourceKeys = Set(source.allKeys())
        for key in T.managedFieldKeys where !sourceKeys.contains(key) {
            recordToSave[key] = nil
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
        guard let zone = zoneID ?? activeFamilyZoneID else {
            logger.error("CloudKitService.delete rejected: no zoneID provided and no activeFamilyZoneID available")
            throw CloudKitServiceError.invalidArguments("No zoneID provided and no activeFamilyZoneID available")
        }
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
