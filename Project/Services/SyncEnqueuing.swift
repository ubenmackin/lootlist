//
//  SyncEnqueuing.swift
//  LootList
//
//  Created by Ben Mackin on 8/28/26.
//

import CloudKit
import Foundation

/// WHY narrow seam: services enqueue without depending on concrete coordinator.
@MainActor
protocol SyncEnqueuing: AnyObject {
    func enqueueSave(recordID: CKRecord.ID, isOwner: Bool)
    func enqueueDelete(recordID: CKRecord.ID, isOwner: Bool)
    func batchEnqueueSave(recordIDs: [CKRecord.ID], isOwner: Bool)
    func dequeueSave(recordID: CKRecord.ID)
    func sendPendingChanges() async
    func fetchChanges() async
}

/// WHY shared: read-only and test convenience inits need the same drop-on-the-floor coordinator.
@MainActor
final class NoopSyncEnqueuing: SyncEnqueuing {
    func enqueueSave(recordID _: CKRecord.ID, isOwner _: Bool) {}
    func enqueueDelete(recordID _: CKRecord.ID, isOwner _: Bool) {}
    func batchEnqueueSave(recordIDs _: [CKRecord.ID], isOwner _: Bool) {}
    func dequeueSave(recordID _: CKRecord.ID) {}
    func fetchChanges() async {}
    func sendPendingChanges() async {}
}

@MainActor
extension SyncEnqueuing {
    // WHY defaults: test doubles keep compiling; real engine overrides.
    func dequeueSave(recordID _: CKRecord.ID) {}
    func sendPendingChanges() async {}
    func fetchChanges() async {}
}
