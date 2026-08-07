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
@MainActor
enum OptimisticFailureHandler {
    private static let logger = Logger(subsystem: "com.volcrypt.lootlist", category: "OptimisticFailureHandler")

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
    ) async {
        // 1. A `.notFound` from `cloudKit.save` is definitive evidence of a
        // concurrent delete — CloudKitService wraps `CKError.unknownItem`
        // into `.notFound` when the record no longer exists server-side.
        // Restoring the pre-mutation snapshot would resurrect a record that another
        // device deleted ("zombie record"), so invalidate instead.
        if let serviceError = error as? CloudKitServiceError,
           case .notFound = serviceError
        {
            invalidate(recordID.recordName)
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            toastManager?.show(message: message, type: .error)
            return
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

            if let fresh = try? await cloudKit.fetch(T.self, id: recordID, using: db) {
                upsert(fresh)
            } else if let snapshot {
                upsert(snapshot)
            } else {
                invalidate(recordID.recordName)
            }
        } else {
            // 3. General failure path — restore pre-mutation snapshot or invalidate
            if let snapshot {
                upsert(snapshot)
            } else {
                invalidate(recordID.recordName)
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            toastManager?.show(message: message, type: .error)
        }
    }
}
