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
    /// → fallback to stale cache on transient network failure only.
    ///
    /// - Parameter fallbackToStale: When `true` (default), a transient network
    ///   failure (`networkUnavailable` / retryable / `CKError.network*`) falls
    ///   back to stale cached rows so offline / brand-new-hero reads remain
    ///   available. Non-network CloudKit failures (e.g. `notFound`,
    ///   `permissionFailure`, `serverRecordChanged`) are rethrown even with
    ///   `fallbackToStale == true` so persistent server errors surface to the
    ///   caller per §5 (`CloudKitServiceError`) and the UI can show a retry /
    ///   `StaleDataBanner` instead of silently masking. Pass `false` when the
    ///   caller must never mask errors (explicit FamilyService-style handling).
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
        sortedBy sort: ((T, T) -> Bool)? = nil,
        fallbackToStale: Bool = true
    ) async throws -> [T] {
        let familyName = family.id.recordName
        let cached = fetchCache(familyName)
        let scope: CKDatabase.Scope = appState.activeDatabaseScope
        if cacheService.isCacheAuthoritative(
            familyRecordName: familyName,
            type: type,
            scope: scope
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
            // Cancellation must always propagate.
            if error is CancellationError {
                throw error
            }
            // Only transient network failures fall back to stale cache. Persistent
            // CloudKit errors rethrow so callers can surface them (§5).
            guard fallbackToStale, isTransientNetworkError(error) else {
                throw error
            }
            cacheFirstLogger
                .warning("cacheFirst \(type.rawValue, privacy: .public) CloudKit query failed (transient network), falling back to stale cache: \(error, privacy: .private)")
            let fallback = fetchCache(familyName)
            // Brand-new hero may not be marked fresh yet — return cached rows (even empty) on transient failure rather than throwing.
            let mapped = fallback.map(map)
            if let sort {
                return mapped.sorted(by: sort)
            }
            return mapped
        }
    }

    /// Returns `true` for transient network errors that justify stale-cache
    /// fallback; all other errors should surface to the caller.
    private static func isTransientNetworkError(_ error: Error) -> Bool {
        if let ckError = error as? CKError {
            return ckError.code == .networkUnavailable || ckError.code == .networkFailure
        }
        if let serviceError = error as? CloudKitServiceError {
            switch serviceError {
            case .networkUnavailable, .retryable, .exhaustedBudget:
                return true
            default:
                return false
            }
        }
        return false
    }
}
