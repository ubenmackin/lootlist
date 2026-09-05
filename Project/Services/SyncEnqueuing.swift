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
@MainActor
protocol SyncEnqueuing: AnyObject {
    func enqueueSave(recordID: CKRecord.ID, isOwner: Bool)
    func enqueueDelete(recordID: CKRecord.ID, isOwner: Bool)
    func batchEnqueueSave(recordIDs: [CKRecord.ID], isOwner: Bool)
}

/// WHY shared: read-only and test convenience inits need the same drop-on-the-floor coordinator.
@MainActor
final class NoopSyncEnqueuing: SyncEnqueuing {
    func enqueueSave(recordID _: CKRecord.ID, isOwner _: Bool) {}
    func enqueueDelete(recordID _: CKRecord.ID, isOwner _: Bool) {}
    func batchEnqueueSave(recordIDs _: [CKRecord.ID], isOwner _: Bool) {}
}
