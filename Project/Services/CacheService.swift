//
//  CacheService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os
import SwiftData
import Synchronization

/// Main-actor SwiftData cache — immediate UI source of truth.
@MainActor
@Observable
final class CacheService: CacheServicing {
    let container: ModelContainer?
    var initializationError: Error?
    var toastManager: ToastManager?

    // WHY: Under Swift 6 (SE-0412), `let` constants of Sendable types (`Mutex<T>`) on @MainActor classes
    // are non-isolated and safe to read/lock from any execution context (including deinit) without hops
    // or `nonisolated(unsafe)`. The compiler actively warns against `nonisolated(unsafe)` on Sendable `let`.
    private let backgroundWriterLock = Mutex<BackgroundCacheActor?>(nil)
    private let bootstrapLock = Mutex<Bool>(false)

    /// Single off-main writer for every cache mutation, built from this service's own container so
    /// app-level wiring can hand the same instance to the sync stack.
    var backgroundWriter: BackgroundCacheActor? {
        backgroundWriterLock.withLock { $0 }
    }

    let logger = Logger(category: "CacheService")
    private var batchDepth = 0
    // WHY: ViewModel preview instances resolve cache without stamping freshness; a single immutable flag
    // disables all watermark writes for that instance so query-only hosts never promote stale data to fresh.
    let allowsWatermarkStamps: Bool

    #if DEBUG
        @ObservationIgnored
        var ledgerEntryFetchScopes: [String?] = []
    #endif

    /// Version counter incremented on watermark changes to trigger SwiftUI cache recomputation.
    var freshnessVersion: Int = 0

    var context: ModelContext? {
        container?.mainContext
    }

    let defaults: UserDefaults
    private let inMemory: Bool

    init(inMemory: Bool = false, defaults: UserDefaults = .standard, skipWatermarkResolutionForViewModels: Bool = false) throws {
        self.defaults = defaults
        self.inMemory = inMemory
        self.allowsWatermarkStamps = !skipWatermarkResolutionForViewModels
        // WHY attempt lightweight: V9/V10 share identical property sets so upgrades attempt lightweight with destructive reset on failure.
        let schema = Schema(LootListSchemaV10.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            // WHY destructive reset: incompatible cache rows wipe and rehydrate via sync engine, no backfill.
            logger.error("Failed to create ModelContainer; error category=\(Self.errorCategory(error), privacy: .public). Recreating store...")
            if !inMemory {
                let url = config.url
                do { try FileManager.default.removeItem(at: url) } catch {
                    logger.warning("Failed to remove store file; error category=\(Self.errorCategory(error), privacy: .public)")
                }
                let shmUrl = url.deletingPathExtension().appendingPathExtension("store-shm")
                let walUrl = url.deletingPathExtension().appendingPathExtension("store-wal")
                do { try FileManager.default.removeItem(at: shmUrl) } catch {
                    logger.debug("Failed to remove shm file; error category=\(Self.errorCategory(error), privacy: .public)")
                }
                do { try FileManager.default.removeItem(at: walUrl) } catch {
                    logger.debug("Failed to remove wal file; error category=\(Self.errorCategory(error), privacy: .public)")
                }
            }
            do {
                container = try ModelContainer(for: schema, configurations: config)
            } catch {
                logger.error("Failed to recreate ModelContainer; error category=\(Self.errorCategory(error), privacy: .public)")
                container = nil
                initializationError = error
            }
        }
        // In-memory stores keep main-actor writes so test seeding and assertions stay synchronous.
        if !inMemory {
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                _ = await self.createAndAttachWriterIfNeeded()
            }
        }
    }

    deinit {
        // WHY: background bootstrap Task may be cancelled on teardown before deferred flag reset runs; clearing here ensures flag never remains stuck under cancellation.
        bootstrapLock.withLock { $0 = false }
    }

    /// Safe, non-crashing in-memory fallback `CacheService` for fallback paths and test scenarios.
    static func inMemoryFallback(logger: Logger? = nil) -> CacheService {
        if let service = makeInMemoryFallbackOrNil(logger: logger) {
            return service
        }
        logger?.fault("Critical: CacheService fallback store failed — running in degraded network-direct mode")
        return CacheService(degradedDefaults: .standard)
    }

    /// Degraded initialization when all ModelContainer creations fail.
    private init(degradedDefaults: UserDefaults) {
        self.defaults = degradedDefaults
        self.inMemory = true
        self.container = nil
        self.initializationError = CacheServiceError.inMemoryFallbackFailed
        self.allowsWatermarkStamps = true
    }

    /// Optional helper that never recurses: attempts twice then returns nil on double failure.
    static func makeInMemoryFallbackOrNil(logger: Logger? = nil) -> CacheService? {
        do {
            return try CacheService(inMemory: true)
        } catch {
            logger?.error("Failed to create in-memory fallback CacheService: \(error, privacy: .private)")
        }
        do {
            return try CacheService(inMemory: true, defaults: .standard)
        } catch {
            logger?.fault("Critical: CacheService fallback store failed: \(error, privacy: .private)")
            return nil
        }
    }

    /// WHY throwing alias: callers that must distinguish failure ride the same two-attempt path.
    static func makeInMemoryFallback(logger: Logger? = nil) throws -> CacheService {
        if let service = makeInMemoryFallbackOrNil(logger: logger) {
            return service
        }
        throw CacheServiceError.inMemoryFallbackFailed
    }

    /// Attaches a writer created off the main actor. The writer is hoisted as a
    /// long-lived singleton; callers must not recreate it per-call.
    func attachBackgroundWriter(_ writer: BackgroundCacheActor) {
        backgroundWriterLock.withLock { current in
            if current == nil {
                current = writer
            }
        }
    }

    /// Whether a background writer is attached; batched upserts can then
    /// coalesce into a single `saveContext()` on that actor.
    var hasBackgroundWriter: Bool {
        backgroundWriterLock.withLock { $0 != nil }
    }

    /// Async bootstrap for call sites that can await before publishing.
    func bootstrapBackgroundWriterIfNeeded() async {
        _ = await createAndAttachWriterIfNeeded()
    }

    /// Consolidated test-and-set bootstrap: guards, lock, writer creation and attach.
    /// Returns true when a new writer was attached, false when bootstrap was skipped.
    private func createAndAttachWriterIfNeeded() async -> Bool {
        guard !inMemory, !hasBackgroundWriter, let container else { return false }
        let shouldCreate = bootstrapLock.withLock { flag in
            if flag {
                return false
            }
            flag = true
            return true
        }
        guard shouldCreate else { return false }
        defer { bootstrapLock.withLock { $0 = false } }
        // WHY: Task cancelled while writer creation was in flight must still clear flag via defer; explicit cancellation checks bail before awaiting detached creation.
        if Task.isCancelled {
            return false
        }
        guard !hasBackgroundWriter else { return false }
        if Task.isCancelled {
            return false
        }
        let writer = await BackgroundCacheActor.makeBackgroundWriter(for: container)
        if Task.isCancelled {
            return false
        }
        attachBackgroundWriter(writer)
        return true
    }

    private static func errorCategory(_ error: Error) -> String {
        String(describing: type(of: error))
    }

    func withBatch(_ work: () -> Void) {
        batchDepth += 1
        defer {
            batchDepth -= 1
            saveContext()
        }
        work()
    }

    func trySaveContext() throws {
        guard let context else { return }
        try context.save()
    }

    @discardableResult
    func saveContext() -> Bool {
        guard batchDepth == 0 else { return true }
        do {
            try trySaveContext()
            return true
        } catch {
            logger.error("Failed to save context: \(error, privacy: .private)")
            toastManager?.show(message: "We couldn't save your changes. Please try again.", type: .error)
            return false
        }
    }

    // MARK: - Freshness Watermark

    private static let freshnessKeyPrefix = "cache_fresh_"

    // WHY: Test-only stamping helper that preserves unscoped semantics (legacy + both scopes)
    // without surfacing deprecated-warning noise in CI when -warnings-as-errors is enabled;
    // production must use scoped overload.
    func markCacheFreshForTests(familyRecordName: String, type: CachedRecordType, at date: Date = Date()) {
        defaults.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type))
        for scope in [CKDatabase.Scope.private, .shared] {
            defaults.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
        }
        freshnessVersion &+= 1
    }

    /// Stamps freshness for record type in the specified database scope.
    func stampCacheWatermarks(for types: Set<CachedRecordType>, scope: CKDatabase.Scope, familyRecordName: String) {
        guard allowsWatermarkStamps else {
            #if DEBUG
                logger.debug("Watermark stamps skipped — viewModel instance is watermark-stamp-disabled")
            #endif
            return
        }
        let family = normalizedFamily(familyRecordName)
        guard !family.isEmpty else { return }
        for type in types {
            markCacheFresh(familyRecordName: family, type: type, scope: scope)
        }
    }

    func stampCacheWatermarks(for types: [CachedRecordType], scope: CKDatabase.Scope, familyRecordName: String) {
        stampCacheWatermarks(for: Set(types), scope: scope, familyRecordName: familyRecordName)
    }

    /// WHY alias: singular stamp stays behind the set path so key derivation never drifts.
    func stampCacheWatermark(for type: CachedRecordType, scope: CKDatabase.Scope, familyRecordName: String) {
        stampCacheWatermarks(for: Set([type]), scope: scope, familyRecordName: familyRecordName)
    }

    /// WHY alias: scope-array fan-out shares the set path so multi-scope stamps stay identical.
    func stampCacheWatermarkForScopes(familyRecordName: String, type: CachedRecordType, scopes: [CKDatabase.Scope]) {
        for scope in scopes {
            stampCacheWatermark(for: type, scope: scope, familyRecordName: familyRecordName)
        }
    }

    // WHY: AnyContainer overload preserves legacy call sites that resolve ModelContainer dynamically;
    // normalizing family via the single helper keeps key derivation identical across overloads.
    func stampCacheWatermarkAnyContainer(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope, containers: [ModelContainer]) {
        let family = normalizedFamily(familyRecordName)
        guard !family.isEmpty else { return }
        guard allowsWatermarkStamps else {
            #if DEBUG
                logger.debug("Watermark stamp skipped — viewModel instance is watermark-stamp-disabled")
            #endif
            return
        }
        // WHY: Deterministic resolution prefers the service's own container when present so
        // repeated calls are stable regardless of container ordering.
        let resolved = container.flatMap { known in containers.first(where: { $0 === known }) } ?? containers.first
        _ = resolved
        markCacheFresh(familyRecordName: family, type: type, scope: scope)
    }

    func markCacheFresh(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope, at date: Date = Date()) {
        defaults.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
        freshnessVersion &+= 1
    }

    /// Returns true if freshness watermark was stamped for the given family, type, and scope.
    func isCacheFresh(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope) -> Bool {
        _ = freshnessVersion
        return defaults.object(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope)) != nil
    }

    /// Returns the stored freshness stamp date for the given family, type, and scope, if any.
    func freshnessDate(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope) -> Date? {
        defaults.object(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope)) as? Date
    }

    /// Authoritative freshness check: hydration token existence determines authority.
    func isCacheAuthoritative(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope) -> Bool {
        _ = freshnessVersion
        // WHY: Hydration token authority — authoritative iff a successful sync/reconciliation stamped
        // a watermark for this family/type/scope; immune to device clock skew because no Date() comparison is performed.
        return isCacheFresh(familyRecordName: familyRecordName, type: type, scope: scope)
    }

    // WHY: Scope-encapsulated staleness check — loops private/shared internally so Views never import CloudKit
    // or handle CKDatabase.Scope; empty cache is never stale, otherwise at least one authoritative scope is required.
    func isStale(for family: String, type: CachedRecordType, cachedCount: Int) -> Bool {
        _ = freshnessVersion
        guard !family.isEmpty, cachedCount > 0 else { return false }
        for scope in [CKDatabase.Scope.private, .shared] where isCacheAuthoritative(familyRecordName: family, type: type, scope: scope) {
            return false
        }
        return true
    }

    // WHY: Alias for call sites that prefer explicit non-scoped naming; delegates to scope-encapsulated loop above so View layer stays CloudKit-free.
    func isStaleWithoutScope(for family: String, type: CachedRecordType, cachedCount: Int) -> Bool {
        isStale(for: family, type: type, cachedCount: cachedCount)
    }

    /// Clears freshness watermarks across all scopes for this family and record type.
    func invalidateFreshness(familyRecordName: String, type: CachedRecordType) {
        defaults.removeObject(forKey: freshnessKey(familyRecordName: familyRecordName, type: type))
        for scope in [CKDatabase.Scope.private, .shared] {
            defaults.removeObject(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
        }
        freshnessVersion &+= 1
    }

    /// Clears freshness watermark for this record type in the specified scope.
    func invalidateFreshness(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope) {
        defaults.removeObject(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
        freshnessVersion &+= 1
    }

    func invalidateAllFreshness() {
        let staleKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.freshnessKeyPrefix) }
        for key in staleKeys {
            defaults.removeObject(forKey: key)
        }
        if !staleKeys.isEmpty {
            freshnessVersion &+= 1
        }
    }

    func invalidateFreshness(forFamilyRecordName familyRecordName: String) {
        let prefix = "\(Self.freshnessKeyPrefix)\(familyRecordName)_"
        let staleKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
        for key in staleKeys {
            defaults.removeObject(forKey: key)
        }
        if !staleKeys.isEmpty {
            freshnessVersion &+= 1
        }
    }

    private func freshnessKey(familyRecordName: String, type: CachedRecordType) -> String {
        "\(Self.freshnessKeyPrefix)\(familyRecordName)_\(type.rawValue)"
    }

    private func freshnessKey(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope) -> String {
        let scopeString = switch scope {
        case .private: "private"
        case .shared: "shared"
        case .public: "public"
        @unknown default: "unknown"
        }
        return "\(Self.freshnessKeyPrefix)\(familyRecordName)_\(scopeString)_\(type.rawValue)"
    }

    // MARK: - Deterministic watermark identity

    // WHY: familyRecordName may carry surrounding whitespace from legacy writes; trimming before
    // key derivation guarantees one logical family maps to one watermark key regardless of call-site variance.
    private func normalizedFamily(_ familyRecordName: String) -> String {
        familyRecordName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CacheServiceError: Error {
    case inMemoryFallbackFailed
}

// WHY: fail-open diagnostic — gem-credit path previously returned false silently; logger surfaces dedup/fetch failures for on-call triage without altering idempotency.
private let sharedGemCreditLogger = Logger(category: "CacheService.GemCredit")

/// Shared gem-credit mutation — single transaction keeps ledger and profile
/// in sync and guarantees idempotency via deterministic ledger recordName.
/// Caller must be on BackgroundCacheActor; ModelContext is not MainActor-isolated.
func sharedGemCreditPrepare(
    context: ModelContext,
    ledger: GemLedger,
    profile: Profile
) -> Bool {
    let familyName = ledger.family.recordID.recordName
    let recordName = ledger.id.recordName
    let profileRecordName = ledger.profileRecordName
    do {
        let dup = try context.fetch(FetchDescriptor<GemLedgerCache>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyName }))
        if dup.first != nil {
            return false
        }
    } catch {
        sharedGemCreditLogger.error("Failed to check duplicate gem ledger \(recordName, privacy: .private): \(error, privacy: .private)")
        return false
    }
    let existingRows: [GemLedgerCache]
    do {
        existingRows = try context.fetch(FetchDescriptor<GemLedgerCache>(predicate: #Predicate { $0.profileRecordName == profileRecordName && $0.familyRecordName == familyName }))
    } catch {
        sharedGemCreditLogger.error("Failed to fetch gem ledgers for \(profileRecordName, privacy: .private): \(error, privacy: .private)")
        return false
    }
    let newBalance = existingRows.reduce(0) { $0 + $1.amount } + ledger.amount
    var updated = profile
    updated.gems = newBalance
    context.insert(GemLedgerCache(from: ledger))
    do {
        let pd = FetchDescriptor<ProfileCache>(predicate: #Predicate { $0.recordName == profileRecordName && $0.familyRecordName == familyName })
        if let existing = try context.fetch(pd).first {
            existing.update(from: updated, isServerSync: true)
        } else {
            context.insert(ProfileCache(from: updated))
        }
    } catch {
        sharedGemCreditLogger.error("Failed to fetch/update profile \(profileRecordName, privacy: .private): \(error, privacy: .private)")
        return false
    }
    return true
}
