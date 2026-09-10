//
//  SyncHealthSnapshot.swift
//  LootList
//
//  Created by Ben Mackin on 9/9/26.
//

import Foundation

/// Value-type sync health for Views to render without holding the engine handle.
/// WHY value-type: Views render a snapshot so CloudKit engine types never cross into the View layer.
struct SyncHealthSnapshot: Sendable, Equatable {
    var pendingUploadCount: Int = 0
    var isSyncing: Bool = false
    var lastSyncedAt: Date?
    var syncError: String?
    var lastPushReceivedAt: Date?
    // WHY display-truth: engine-delivered changes land outside coordinator passes, so change age complements full-sync age without promoting freshness.
    var lastChangeReceivedAt: Date?
    var isPrivateEngineActive: Bool = false
    var isSharedEngineActive: Bool = false
    // WHY visible loss: bounded pending buffers drop oldest on cap; the count tracks unresolved dropped
    // writes so partial recovery shows the remaining loss, never a cumulative tally.
    var pendingBufferOverflowed: Bool = false
    var pendingBufferDroppedCount: Int = 0
}
