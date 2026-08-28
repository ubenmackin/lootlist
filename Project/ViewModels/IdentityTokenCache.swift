//
//  IdentityTokenCache.swift
//  LootList
//
//  Created by Ben Mackin on 8/28/26.
//

import CryptoKit
import Foundation

/// Actor-isolated cache for opaque identity tokens.
///
/// Serializes SHA256 token generation so concurrent `refreshInvitations`
/// re-entrancy on `@MainActor` cannot race on a plain dictionary. Each
/// unique identity key maps to a single stable token for SwiftUI row identity
/// and survives re-entrancy during the async CloudKit fetch window.
actor IdentityTokenCache {
    private var cache: [String: String] = [:]

    /// Returns a stable token for `value`, computing SHA256 on first encounter
    /// and reusing the cached result thereafter.
    func token(for value: String) -> String {
        if let cached = cache[value] {
            return cached
        }
        let digest = SHA256.hash(data: Data(value.utf8))
        let result = digest.hex
        cache[value] = result
        return result
    }

    /// Snapshot of cached tokens for inspection in tests.
    func cachedTokens() -> [String: String] {
        cache
    }

    func removeAll() {
        cache.removeAll()
    }
}
