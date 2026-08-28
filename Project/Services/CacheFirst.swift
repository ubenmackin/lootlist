//
//  CacheFirst.swift
//  LootList
//
//  Created by Ben Mackin on 8/28/26.
//

import CloudKit
import Foundation
import os

private let cacheFirstLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "LootList",
    category: "CacheFirst"
)

/// Generic cache-first scaffold that consolidates six duplicated read paths.
///
/// Single-point scope-aware freshness fix — every caller rides this helper so
/// a scope-isolation change applies once.
enum CacheFirst {
    /// Core generic helper.
    ///
    /// Encapsulates: check `isCacheAuthoritative(scope-aware)` → return cached
    /// rows mapped (and optionally sorted) → CloudKit query → `hydrateFromQuery`
    /// → fallback to stale cache on catch with `logger.warning`.
    @MainActor
    static func cacheFirst<T: CloudKitRecord, C: FamilyScopedCache>(
        type: CachedRecordType,
        family: Family,
        cacheService: CacheService,
        appState: AppState,
        fetchCache: (String) -> [C],
        map: (C) -> T,
        query: () async throws -> [T],
        hydrate: ([T]) async -> Void,
        sortedBy sort: ((T, T) -> Bool)? = nil
    ) async throws -> [T] {
        let familyName = family.id.recordName
        let cached = fetchCache(familyName)
        let scope: CKDatabase.Scope = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared
        if cacheService.isCacheAuthoritative(
            familyRecordName: familyName,
            type: type,
            scope: scope,
            cachedCount: cached.count
        ) {
            let mapped = cached.map(map)
            if let sort {
                return mapped.sorted(by: sort)
            }
            return mapped
        }

        do {
            let queried = try await query()
            await hydrate(queried)
            if let sort {
                return queried.sorted(by: sort)
            }
            return queried
        } catch {
            // WHY: stale cache must re-validate via CloudKit; offline fallback renders stale cache explicitly at call site, not via authoritative predicate.
            cacheFirstLogger.warning("cacheFirst \(type.rawValue, privacy: .public) CloudKit query failed, falling back to stale cache: \(error, privacy: .private)")
            let fallback = fetchCache(familyName)
            if !fallback.isEmpty {
                let mapped = fallback.map(map)
                if let sort {
                    return mapped.sorted(by: sort)
                }
                return mapped
            }
            throw error
        }
    }
}

/// Convenience free function matching the blueprint-described signature.
///
/// This overload forwards to ``CacheFirst/cacheFirst(type:family:cacheService:appState:fetchCache:map:query:hydrate:sortedBy:)``
/// when callers already have `cacheService` and `appState` in scope via
/// captured closures. Prefer the `CacheFirst` enum entry point for new code.
@MainActor
func cacheFirst<T: CloudKitRecord, C: FamilyScopedCache>(
    type: CachedRecordType,
    family: Family,
    cacheService: CacheService,
    appState: AppState,
    fetchCache: (String) -> [C],
    map: (C) -> T,
    query: () async throws -> [T],
    hydrate: ([T]) async -> Void
) async throws -> [T] {
    try await CacheFirst.cacheFirst(
        type: type,
        family: family,
        cacheService: cacheService,
        appState: appState,
        fetchCache: fetchCache,
        map: map,
        query: query,
        hydrate: hydrate
    )
}
