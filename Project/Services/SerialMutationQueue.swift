//
//  SerialMutationQueue.swift
//  LootList
//
//  Created by Ben Mackin on 8/20/26.
//

import Foundation

/// Linearizes background cache commits and reconciliation passes to prevent overlapping saves.
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
            // resumes exactly once — actor-isolated, no onCancel needed
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
