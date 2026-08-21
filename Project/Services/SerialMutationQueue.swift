//
//  SerialMutationQueue.swift
//  LootList
//
//  Created by Ben Mackin on 8/20/26.
//

import Foundation

/// Async-semaphore gate that linearizes background-actor batch commits
/// against the shared ModelContainer. The sole call site is
/// `BackgroundCacheActor.batchUpsertParsedRecords`, which holds the gate for
/// the duration of each batch commit so concurrent engine passes (e.g. the
/// private and shared engines racing) cannot interleave.
///
/// Actors are reentrant across suspension, so actor isolation alone provides
/// no mutual exclusion here — the exclusion comes from the gate: a writer
/// holds it for the full duration of its operation while later callers park
/// on checked continuations in FIFO order. This closes TOCTOU races such as
/// simultaneous fetch → mutate → save transactions for the same record.
///
/// This gate coexists with the finer-grained per-path guards (`Mutex`
/// in-flight sets, `GemLock` period locks); it serializes whole write
/// operations and does not replace those narrower mechanisms.
actor SerialMutationQueue {
    static let shared = SerialMutationQueue()

    private var isGateHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

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
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isGateHeld = true
        }
    }

    /// Transfers gate ownership directly to the next waiter (keeping it held),
    /// or releases it when no one is queued.
    private func release() {
        if waiters.isEmpty {
            isGateHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
