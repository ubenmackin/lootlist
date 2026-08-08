//
//  OptimisticFailureHandler.swift
//  LootList
//
//  Created by Ben Mackin on 8/06/26.
//

import CloudKit
import Foundation
import OSLog

/// Consolidated recovery logic for optimistic write save failures across domain services.
/// Handles `.notFound` (zombie record prevention), concurrent edit divergence detection,
/// CloudKit re-fetching, cache restoration/invalidation, and user toast notifications.
///
/// The handler is the sole recovery path: one call site per service catch block,
/// with no inline recovery cascades at the call sites. It owns re-fetch-or-restore-or-invalidate,
/// and returns the recovered record (`T?`) so a recovering caller (e.g. `XPService.addXP`)
/// can return the cache-coherent value to its caller — the freshly-fetched server record on a
/// concurrent edit, the pre-mutation snapshot on a general-failure restore, or `nil` on the
/// invalidate path (zombie deletion, no prior snapshot, or re-fetch miss with no snapshot).
/// Upsert-or-invalidate still mutates the cache as before; the return value is the same record
/// the cache now holds, so a recovering caller's return value can never diverge from the cache.
/// Discarding the return value (the default for the other mutation services, which `throw` their
/// own domain error after the cache is reconciled) is fine — `@discardableResult` silences the
/// unused-result warning at those sites.
@MainActor
enum OptimisticFailureHandler {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "OptimisticFailureHandler")

    @discardableResult
    static func handleSaveFailure<T: CloudKitRecord>(
        recordID: CKRecord.ID,
        preMutationChangeTag: String? = nil,
        snapshot: T? = nil,
        cloudKit: any CloudKitServiceProtocol,
        toastManager: ToastManager?,
        fetchCurrentTag: () -> String?,
        upsert: (T) -> Void,
        invalidate: (String) -> Void,
        error: Error,
        db: CKDatabase? = nil
    ) async -> T? {
        // 1. A `.notFound` from `cloudKit.save` is definitive evidence of a
        // concurrent delete — CloudKitService wraps `CKError.unknownItem`
        // into `.notFound` when the record no longer exists server-side.
        // Restoring the pre-mutation snapshot would resurrect a record that another
        // device deleted ("zombie record"), so invalidate instead. The recovered
        // record is nil: the cache no longer holds it and there is no truth to return.
        if let serviceError = error as? CloudKitServiceError,
           case .notFound = serviceError
        {
            invalidate(recordID.recordName)
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            toastManager?.show(message: message, type: .error)
            return nil
        }

        // 2. Check for concurrent edit divergence on another device
        let concurrentEditDetected = ConcurrentEditDetector.detectConcurrentEdit(
            preMutationChangeTag: preMutationChangeTag,
            fetchCurrent: fetchCurrentTag,
            error: error
        )

        if concurrentEditDetected {
            toastManager?.show(
                message: "Data was modified by another device. Refresh to see the latest.",
                type: .warning
            )

            // The authoritative server record is the recovered record on this path: it is
            // the same record the cache now holds (`upsert(fresh)` below). Falling back to the
            // pre-mutation snapshot (re-fetch miss) makes the snapshot the recovered record,
            // again matching the cache. The invalidate path has nothing coherent to return, so
            // it yields nil — a recovering caller falls through to its own pre-mutation source.
            if let fresh = try? await cloudKit.fetch(T.self, id: recordID, using: db) {
                upsert(fresh)
                return fresh
            } else if let snapshot {
                upsert(snapshot)
                return snapshot
            } else {
                invalidate(recordID.recordName)
                return nil
            }
        } else {
            // 3. General failure path — restore pre-mutation snapshot or invalidate. The
            // restored snapshot is the recovered record (it is what the cache now holds);
            // the invalidate path yields nil since the cache no longer carries the record.
            // The error toast is shown for both branches: the user sees a save-failed
            // notice whether the row was restored or invalidated.
            let recovered: T?
            if let snapshot {
                upsert(snapshot)
                recovered = snapshot
            } else {
                invalidate(recordID.recordName)
                recovered = nil
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            toastManager?.show(message: message, type: .error)
            return recovered
        }
    }
}
