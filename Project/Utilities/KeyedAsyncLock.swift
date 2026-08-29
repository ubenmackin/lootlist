//
//  KeyedAsyncLock.swift
//  LootList
//
//  Created by Ben Mackin on 8/28/26.
//

import Foundation

/// Serializes concurrent asynchronous operations on the same string key.
actor KeyedAsyncLock {
    private var locked = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func withLock<T: Sendable>(key: String, _ body: @MainActor () async throws -> T) async rethrows -> T {
        await lock(key: key)
        defer { unlock(key: key) }
        return try await body()
    }

    private func lock(key: String) async {
        if !locked.contains(key) {
            locked.insert(key)
            return
        }
        // Resumes exactly once — actor-isolated, no onCancel needed.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[key, default: []].append(continuation)
        }
    }

    private func unlock(key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            if queue.isEmpty {
                waiters.removeValue(forKey: key)
            } else {
                waiters[key] = queue
            }
            next.resume()
        } else {
            locked.remove(key)
        }
    }
}

/// Backward compatibility alias for GemLock.
typealias GemLock = KeyedAsyncLock
