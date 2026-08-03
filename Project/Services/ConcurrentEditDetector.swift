//
//  ConcurrentEditDetector.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

/// Actor-isolated registry of record names currently under an optimistic
/// mutation — i.e. between the local cache write and the `await cloudKit.save`
/// settling (success or terminal failure).
///
/// During that optimistic window a background incremental sync can
/// overwrite the in-flight row with stale server data (transient UI flicker),
/// and the changeTag signal only fires on save failure, not on background
/// overwrite. Mutation services therefore `register` the recordName before
/// their optimistic upsert and `deregister` once the CloudKit save settles;
/// `BackgroundCacheActor.batchUpsert*` consults this registry and skips rows
/// that are currently in-flight — they are the optimistic author's
/// responsibility, and the post-save re-upsert reconciles them.
actor InFlightMutationRegistry {
    private var keys = Set<String>()

    /// Marks `key` as being written optimistically. Called by mutation
    /// services immediately before the local cache upsert. Keys may be bare
    /// record names or namespaced by mutation role (e.g., `"xpBank:recordName"`).
    func register(_ key: String) {
        keys.insert(key)
    }

    /// Removes `key` from the in-flight set. Called once the CloudKit
    /// save settles — success or terminal failure (the rollback runs while the
    /// name is still registered so the sync keeps its hands off it).
    func deregister(_ key: String) {
        keys.remove(key)
    }

    /// Returns true when `query` (either exact key or matching underlying recordName)
    /// is currently under an optimistic mutation.
    func contains(_ query: String) -> Bool {
        if keys.contains(query) {
            return true
        }
        let recordName = extractRecordName(from: query)
        return activeRecordNames().contains(recordName)
    }

    /// Snapshots the set of active record names (with any role namespace prefix stripped).
    /// Used by `BackgroundCacheActor` to filter a whole batch in one actor hop.
    func activeRecordNames() -> Set<String> {
        Set(keys.map { extractRecordName(from: $0) })
    }

    private func extractRecordName(from key: String) -> String {
        guard let colonIndex = key.firstIndex(of: ":") else { return key }
        return String(key[key.index(after: colonIndex)...])
    }
}

/// Detects whether another device (or this device's background sync) has
/// applied a conflicting mutation while an in-flight CloudKit save was failing.
///
/// Two independent signals are checked; either one is sufficient evidence of
/// a concurrent edit:
///   1) CloudKit raised a `serverRecordChanged` error during `cloudKit.save`.
///      CloudKitService wraps raw `CKError` instances into
///      `CloudKitServiceError` before throwing, so we pattern-match the
///      wrapped form — `CloudKitServiceError.serverRecordChanged`
///      — rather than `CKError` itself, which the service layer never sees.
///   2) The cache row's current `changeTag` differs from the
///      `preMutationChangeTag` we captured before the optimistic write. A
///      background sync may have pulled Mutation B's update into the cache
///      during the `await cloudKit.save(...)` call, mutating the cached row's
///      changeTag. When both sides are present and unequal, we conclude a
///      concurrent edit landed.
///
/// When neither signal is present (the common case — including, by design,
/// brand-new records, where `preMutationChangeTag == nil` because there was
/// no prior cache row to snapshot), this returns `false` and the caller
/// proceeds with the standard rollback.
///
/// Deletion-during-save is NOT detected here: a record deleted on the server
/// while a mutation was in flight surfaces as `CloudKitServiceError.notFound`
/// from `cloudKit.save` (CloudKitService wraps `CKError.unknownItem`), and the
/// concurrent deletion also removes the cached row — making signal 2's
/// `fetchCurrent` nil and silently false. `QuestService.handleSaveFailure`
/// therefore treats `.notFound` as a definitive concurrent delete and
/// invalidates instead of restoring the snapshot, before this
/// detector is consulted.
enum ConcurrentEditDetector {
    static func detectConcurrentEdit(
        preMutationChangeTag: String?,
        fetchCurrent: () -> String?,
        error: Error
    ) -> Bool {
        // Signal 1: CloudKit's canonical optimistic-concurrency conflict.
        if let serviceError = error as? CloudKitServiceError,
           serviceError == .serverRecordChanged
        {
            return true
        }

        // Signal 2: changeTag divergence detected via a cache re-fetch.
        let currentChangeTag = fetchCurrent()
        return {
            guard let pre = preMutationChangeTag,
                  let cur = currentChangeTag,
                  !cur.isEmpty
            else { return false }
            return pre != cur
        }()
    }
}
