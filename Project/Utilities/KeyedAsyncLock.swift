//
//  KeyedAsyncLock.swift
//  LootList
//
//  Created by Ben Mackin on 8/28/26.
//

import Foundation
import Synchronization

/// Serializes concurrent asynchronous operations on the same string key.
actor KeyedAsyncLock {
    private var locked = Set<String>()

    private struct WaiterEntry: Sendable {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [String: [WaiterEntry]] = [:]

    func withLock<T: Sendable>(key: String, _ body: @MainActor () async throws -> T) async throws -> T {
        var acquired = false
        defer {
            if acquired {
                unlock(key: key)
            }
        }
        try await lock(key: key)
        acquired = true
        return try await body()
    }

    private func lock(key: String) async throws {
        if !locked.contains(key) {
            locked.insert(key)
            return
        }
        // Box shares the waiter ticket ID between the suspending operation and the cancellation handler.
        let box = Mutex<UUID?>(nil)
        do {
            try await withTaskCancellationHandler(operation: {
                try await self.suspend(key: key, box: box)
            }, onCancel: {
                guard let ticketID = box.withLock({ $0 }) else { return }
                Task { await self.cancelWaiter(id: ticketID, for: key) }
            })
        } catch {
            throw error
        }
    }

    private func suspend(key: String, box: borrowing Mutex<UUID?>) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let ticketID = UUID()
            let waiter = WaiterEntry(id: ticketID, continuation: continuation)
            box.withLock { $0 = ticketID }
            waiters[key, default: []].append(waiter)
            // If the task was already cancelled before the waiter was enqueued,
            // the withTaskCancellationHandler onCancel may have fired before
            // box was populated and missed removal. Re-check and clean up.
            if Task.isCancelled {
                self.cancelWaiter(id: ticketID, for: key)
            }
        }
    }

    private func cancelWaiter(id: UUID, for key: String) {
        guard var queue = waiters[key] else { return }
        guard let index = queue.firstIndex(where: { $0.id == id }) else {
            // Already resumed by unlock — nothing to do.
            return
        }
        let waiter = queue.remove(at: index)
        if queue.isEmpty {
            waiters.removeValue(forKey: key)
        } else {
            waiters[key] = queue
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func unlock(key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            if queue.isEmpty {
                waiters.removeValue(forKey: key)
            } else {
                waiters[key] = queue
            }
            next.continuation.resume()
        } else {
            locked.remove(key)
        }
    }
}

/// Backward compatibility alias for GemLock.
typealias GemLock = KeyedAsyncLock
