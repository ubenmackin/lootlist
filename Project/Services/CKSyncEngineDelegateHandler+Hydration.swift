//
//  CKSyncEngineDelegateHandler+Hydration.swift
//  LootList
//
//  Created by Ben Mackin on 8/25/26.
//

import CloudKit
import Foundation

@MainActor
extension CKSyncEngineDelegateHandler {
    /// Feeds query results back through the single server→cache ingestion path.
    func hydrateFromQuery(
        models: [some CloudKitRecord],
        databaseScope: CKDatabase.Scope,
        zoneID: CKRecordZone.ID
    ) async {
        // Hydrated rows must ride the single ingestion pipeline rather than
        // being upserted directly: a direct write drops the record's encoded
        // system fields and can clobber unsynced local edits. The round-trip
        // through `toRecord()` preserves them.
        let records = models.map { $0.toRecord() }
        guard !records.isEmpty else { return }
        await ingest(
            records: records,
            databaseScope: databaseScope,
            zoneID: zoneID,
            // Hydration is a server→local reconciliation pass, not a new
            // event the user acted on — the records it ingests already
            // fired their notifications on whichever device authored them.
            notifiesOnCompletion: false
        )
    }
}
