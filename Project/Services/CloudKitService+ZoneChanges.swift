//
//  CloudKitService+ZoneChanges.swift
//  LootList
//
//  Created by Ben Mackin on August 6, 2026.
//

import CloudKit
import Foundation

extension CloudKitService {
    func fetchZoneChanges(
        in zoneID: CKRecordZone.ID? = nil,
        since token: CKServerChangeToken? = nil,
        using db: CKDatabase? = nil
    ) async throws -> ZoneChangesResult {
        if isTestingOrMocking {
            return ZoneChangesResult(
                changedRecords: Array(mockRecords.values),
                deletedRecordIDs: [],
                newToken: nil,
                moreComing: false
            )
        }

        let zone = zoneID ?? resolvedZoneID
        let targetDB = db ?? activeFamilyDatabase

        return try await retrying {
            var changedRecords: [CKRecord] = []
            var deletedRecordIDs: [(recordID: CKRecord.ID, recordType: String)] = []
            var newToken = token
            var moreComing = true

            while moreComing {
                let changes = try await targetDB.recordZoneChanges(inZoneWith: zone, since: newToken)

                for (_, result) in changes.modificationResultsByID {
                    if case let .success(modification) = result {
                        changedRecords.append(modification.record)
                    }
                }
                for deletion in changes.deletions {
                    deletedRecordIDs.append((deletion.recordID, deletion.recordType))
                }

                newToken = changes.changeToken
                moreComing = changes.moreComing
            }

            return ZoneChangesResult(
                changedRecords: changedRecords,
                deletedRecordIDs: deletedRecordIDs,
                newToken: newToken,
                moreComing: moreComing
            )
        }
    }
}
