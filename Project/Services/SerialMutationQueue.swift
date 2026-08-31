//
//  SerialMutationQueue.swift
//  LootList
//
//  Created by Ben Mackin on 8/20/26.
//

import Foundation

/// Linearizes background cache commits and reconciliation passes to prevent overlapping saves.
///
/// Process-wide serialization gate — intentionally a singleton. `BackgroundCacheActor`
/// (via `mutationQueue`) and the `CKSyncEngineDelegateHandler` ingest path share a
/// single `ModelContext` save boundary; overlapping batch commits would interleave
/// `ModelContext` mutations and corrupt the store. `shared` guarantees that only
/// one upsert/reconcile transaction holds the gate at a time across all actors.
/// Do not replace with per-actor queues.
actor SerialMutationQueue {
    /// Intentional process-wide singleton; see type-level docs for why this
    /// cannot be per-instance.
    static let shared = SerialMutationQueue()
    private var isGateHeld = false
    private struct Waiter: Sendable {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var waiters: [Waiter] = []

    /// Executes `operation` while holding the gate, guaranteeing that no two
    /// writes interleave. The closure runs off-actor; the gate — not actor
    /// isolation — provides the exclusion.
    func write<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if isGateHeld {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if Task.isCancelled {
                        continuation.resume()
                    } else {
                        waiters.append(Waiter(id: id, continuation: continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id: id) }
            }
        } else {
            isGateHeld = true
        }
    }

    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume()
        }
    }

    /// Transfers gate ownership directly to the next waiter (keeping it held),
    /// or releases it when no one is queued.
    private func release() {
        if waiters.isEmpty {
            isGateHeld = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}
