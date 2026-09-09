//
//  AppLifecycleCoordinator+SyncHealth.swift
//  LootList
//
//  Created by Ben Mackin on 9/9/26.
//

import Foundation

/// WHY lifecycle vends health: Views read sync state from the lifecycle layer
/// so the CloudKit engine handle never crosses into the View layer.
extension AppLifecycleCoordinator {
    /// WHY fail-closed: missing engine reads as empty health so Views render stale, never synced.
    var syncHealthSnapshot: SyncHealthSnapshot {
        guard let coordinator = syncCoordinator as? CKSyncEngineCoordinator else {
            return SyncHealthSnapshot()
        }
        return SyncHealthSnapshot(
            pendingUploadCount: coordinator.pendingUploadCount,
            isSyncing: coordinator.isSyncing,
            lastSyncedAt: coordinator.lastSyncedAt,
            syncError: coordinator.syncError,
            lastPushReceivedAt: coordinator.lastPushReceivedAt,
            isPrivateEngineActive: coordinator.activeEngine(isOwner: true) != nil,
            isSharedEngineActive: coordinator.activeEngine(isOwner: false) != nil
        )
    }

    /// WHY fail-closed: missing engine reads as zero pending so footnotes never invent uploads.
    var syncPendingUploadCount: Int {
        (syncCoordinator as? CKSyncEngineCoordinator)?.pendingUploadCount ?? 0
    }

    /// WHY fail-closed: missing engine reads as never-synced so relative copy stays honest.
    var syncLastSyncedAt: Date? {
        (syncCoordinator as? CKSyncEngineCoordinator)?.lastSyncedAt
    }

    /// WHY fail-closed: missing engine reads as no error so banners never invent failures.
    var syncErrorText: String? {
        (syncCoordinator as? CKSyncEngineCoordinator)?.syncError
    }
}
