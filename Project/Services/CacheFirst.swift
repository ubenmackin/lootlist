//
//  CacheFirst.swift
//  LootList
//
//  Created by Ben Mackin on 8/28/26.
//

import CloudKit
import Foundation
import os

private let cacheFirstLogger = Logger(category: "CacheFirst")

/// Generic cache-first scaffold that consolidates six duplicated read paths.
///
/// Single-point scope-aware freshness fix — every caller rides this helper so
/// a scope-isolation change applies once.
/// WHY derivation split: UI live reads use @Query plus bucketBalances/totalBalance cache-only; this helper serves derivation reconcile only.
enum CacheFirst {
    /// WHY bundle: groups read-path closures so the helper stays under the lint parameter limit.
    struct Operations<T: CloudKitRecord, C: FamilyScopedCache> {
        let fetchCache: (String) -> [C]
        let map: (C) -> T
        let query: () async throws -> [T]
        let hydrate: ([T]) async -> Void
        let sortedBy: ((T, T) -> Bool)?
        let fallbackToStale: Bool

        init(
            fetchCache: @escaping (String) -> [C],
            map: @escaping (C) -> T,
            query: @escaping () async throws -> [T],
            hydrate: @escaping ([T]) async -> Void,
            sortedBy: ((T, T) -> Bool)? = nil,
            fallbackToStale: Bool = true
        ) {
            self.fetchCache = fetchCache
            self.map = map
            self.query = query
            self.hydrate = hydrate
            self.sortedBy = sortedBy
            self.fallbackToStale = fallbackToStale
        }
    }

    /// WHY derivation-only: payout and export reconcile against CloudKit; UI tiles use @Query plus bucketBalances/totalBalance cache-only.
    /// WHY single gate: authoritative cache renders instantly, transient failures fall back to stale.
    @MainActor
    static func cacheFirst<T: CloudKitRecord>(
        type: CachedRecordType,
        family: Family,
        cacheService: any CacheServicing,
        scope: CKDatabase.Scope,
        operations: Operations<T, some FamilyScopedCache>
    ) async throws -> [T] {
        let familyName = family.id.recordName
        let cached = operations.fetchCache(familyName)
        // WHY single scope: gate and hydrate share one captured value.
        if cacheService.isCacheAuthoritative(
            familyRecordName: familyName,
            type: type,
            scope: scope
        ) {
            // WHY: hydrated cache renders instantly; network reconciles in background.
            let mapped = cached.map(operations.map)
            if let sort = operations.sortedBy {
                return mapped.sorted(by: sort)
            }
            return mapped
        }

        do {
            let queried = try await operations.query()
            // WHY ingest-only: hydrate rides ingest with notifiesOnCompletion false so reconcile never notifies.
            await operations.hydrate(queried)
            if let sort = operations.sortedBy {
                return queried.sorted(by: sort)
            }
            return queried
        } catch {
            // Cancellation must always propagate.
            if error is CancellationError {
                throw error
            }
            // Only transient network failures fall back to stale cache. Persistent
            // CloudKit errors rethrow so callers can surface them (§5).
            guard operations.fallbackToStale, CloudKitErrorClassifier.isTransient(error) else {
                throw error
            }
            cacheFirstLogger
                .warning("cacheFirst \(type.rawValue, privacy: .public) CloudKit query failed (transient network), falling back to stale cache: \(error, privacy: .private)")
            let fallback = operations.fetchCache(familyName)
            // Brand-new hero may not be marked fresh yet — return cached rows (even empty) on transient failure rather than throwing.
            // WHY no stamp: empty cache stays non-authoritative until a clean ingest pass stamps freshness.
            let mapped = fallback.map(operations.map)
            if let sort = operations.sortedBy {
                return mapped.sorted(by: sort)
            }
            return mapped
        }
    }

    /// WHY single source: quest-log and payout paths patch CloudKit-missing
    /// keys over the cached snapshot identically; drift under-counts rewards.
    @MainActor
    static func stitch<T: CloudKitRecord>(
        needed: Set<String>,
        cached: [T],
        fetchMissing: ([String]) async throws -> [T]
    ) async throws -> [T] where T.ID == CKRecord.ID {
        guard !needed.isEmpty else { return [] }
        var map = Dictionary(uniqueKeysWithValues: cached.map { ($0.id.recordName, $0) })
        let missing = needed.filter { map[$0] == nil }
        if missing.isEmpty {
            return cached.filter { needed.contains($0.id.recordName) }
        }
        let fetched = try await fetchMissing(Array(missing))
        for item in fetched {
            map[item.id.recordName] = item
        }
        return Array(map.values).filter { needed.contains($0.id.recordName) }
    }

    /// WHY derivation-only: payout gold math reconciles here; UI tiles use @Query plus bucketBalances/totalBalance cache-only.
    /// WHY single gate: stitched merge when fresh, direct missing fetch
    /// otherwise so brand-new-hero reads still resolve without cache writes.
    @MainActor
    static func resolveWithCache<T: CloudKitRecord>(
        needed: Set<String>,
        isAuthoritative: Bool,
        fetchCached: () -> [T],
        fetchMissing: ([String]) async throws -> [T]
    ) async throws -> [T] where T.ID == CKRecord.ID {
        if isAuthoritative {
            return try await stitch(needed: needed, cached: fetchCached(), fetchMissing: fetchMissing)
        }
        guard !needed.isEmpty else { return [] }
        return try await fetchMissing(Array(needed))
    }
}
