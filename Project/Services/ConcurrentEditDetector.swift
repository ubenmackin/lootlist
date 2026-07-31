//
//  ConcurrentEditDetector.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

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
