//
//  SyncEnqueuing.swift
//  LootList
//
//  Created by Ben Mackin on 8/28/26.
//

import CloudKit
import Foundation

/// Narrow seam over the sync engine's enqueue surface. Services that mutate
/// the cache enqueue a save or delete through this protocol without
/// depending on the concrete CKSyncEngineCoordinator.
/// WHY: All CloudKit writes must ride CKSyncEngineCoordinator — no direct RecordBridge
/// synthesis or CKDatabase.save outside the coordinator so tombstones and changeTags stay coherent.
@MainActor
protocol SyncEnqueuing: AnyObject {
    func enqueueSave(recordID: CKRecord.ID, isOwner: Bool)
    func enqueueDelete(recordID: CKRecord.ID, isOwner: Bool)
    func batchEnqueueSave(recordIDs: [CKRecord.ID], isOwner: Bool)
}
