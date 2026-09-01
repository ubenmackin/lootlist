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

    /// Single off-main writer for every cache mutation, built from this service's own container so
    /// app-level wiring can hand the same instance to the sync stack.
    private nonisolated(unsafe) let backgroundWriterLock = Mutex<BackgroundCacheActor?>(nil)
    private nonisolated(unsafe) let bootstrapLock = Mutex<Bool>(false)
    var backgroundWriter: BackgroundCacheActor? {
        backgroundWriterLock.withLock { $0 }
    }

    // WHY: iOS 26 native SwiftData cross-context propagation may lag up to ~500ms under memory pressure; didSave fallback bridges background saves to mainContext via processPendingChanges; iOS 27+ native propagation is reliable so observer is skipped.
    private nonisolated(unsafe) var didSaveObserver: NSObjectProtocol?

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "CacheService")
    private var batchDepth = 0

    #if DEBUG
        @ObservationIgnored
        var ledgerEntryFetchScopes: [String?] = []
    #endif

    /// Version counter incremented on watermark changes to trigger SwiftUI cache recomputation.
    var freshnessVersion: Int = 0

    // WHY: Staleness ceiling only needs to cover the normal foreground-catch-up window, yet remain
    // short enough that a backgrounded device which dropped a throttled silent push re-validates on
    // next foreground. One hour is a conservative default; a single named constant keeps tuning trivial.
    nonisolated static let freshnessMaximumAge: TimeInterval = 3600

    var context: ModelContext? {
        container?.mainContext
    }

    let defaults: UserDefaults
    private let inMemory: Bool

    init(inMemory: Bool = false, defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        self.inMemory = inMemory
        let schema = Schema(LootListSchemaV10.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
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
        installDidSaveObserverIfNeeded()
    }

    deinit {
        // WHY: background bootstrap Task may be cancelled on teardown before deferred flag reset runs; clearing here ensures flag never remains stuck under cancellation.
        bootstrapLock.withLock { $0 = false }
        if let observer = didSaveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // WHY: iOS 26 fallback — native cross-context propagation may delay @Query refresh up to ~500ms under memory pressure; explicit didSave → processPendingChanges bridging covers flake window. iOS 27+ uses native propagation only.
    private func installDidSaveObserverIfNeeded() {
        if #available(iOS 27, *) {
            return
        }
        guard didSaveObserver == nil, let container else { return }
        let didSaveName = Notification.Name("ModelContextDidSave")
        didSaveObserver = NotificationCenter.default.addObserver(forName: didSaveName, object: nil, queue: .main) { [weak self] _ in
            self?.container?.mainContext.processPendingChanges()
        }
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

    /// Throwing variant for callers that prefer explicit error handling over fatalError.
    static func makeInMemoryFallback(logger: Logger? = nil) throws -> CacheService {
        guard let service = makeInMemoryFallbackOrNil(logger: logger) else {
            throw CacheServiceError.inMemoryFallbackFailed
        }
        return service
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

    /// Stamps freshness watermarks across database scopes for this family and type.
    // WHY: Unscoped overload stamps both scopes + legacy key — retained only as test helper; production paths must use the scoped overload to preserve explicit scope isolation and avoid cross-scope over-stamping.
    @available(*, deprecated, message: "Use scoped markCacheFresh(familyRecordName:type:scope:)")
    func markCacheFresh(familyRecordName: String, type: CachedRecordType, at date: Date = Date()) {
        defaults.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type))
        for scope in [CKDatabase.Scope.private, .shared] {
            defaults.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
        }
        freshnessVersion &+= 1
    }

    // WHY: Test-only stamping helper that preserves unscoped semantics (legacy + both scopes) without surfacing deprecated-warning noise in CI when -warnings-as-errors is enabled; production must use scoped overload.
    func markCacheFreshForTests(familyRecordName: String, type: CachedRecordType, at date: Date = Date()) {
        defaults.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type))
        for scope in [CKDatabase.Scope.private, .shared] {
            defaults.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
        }
        freshnessVersion &+= 1
    }

    /// Stamps freshness for record type in the specified database scope.
    func markCacheFresh(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope, at date: Date = Date()) {
        defaults.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
        freshnessVersion &+= 1
    }

    /// Returns true if a freshness watermark exists for any database scope.
    func isCacheFresh(familyRecordName: String, type: CachedRecordType) -> Bool {
        _ = freshnessVersion
        let legacyKey = freshnessKey(familyRecordName: familyRecordName, type: type)
        if defaults.object(forKey: legacyKey) != nil {
            return true
        }
        for scope in [CKDatabase.Scope.private, .shared]
            where defaults.object(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope)) != nil
        {
            return true
        }
        return false
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

    /// Authoritative freshness check: cached data is served only when a freshness watermark exists
    /// and is still within the staleness window.
    func isCacheAuthoritative(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope) -> Bool {
        _ = freshnessVersion
        // WHY: Wall-clock dependence is accepted after considering monotonic alternatives
        // (CFAbsoluteTimeGetCurrent / ProcessInfo.systemUptime). Forward skew (>1h) makes a fresh
        // watermark appear stale and forces an unnecessary CloudKit query; backward skew makes a
        // stale watermark appear fresh and would serve stale cache as authoritative. The defensive
        // `interval >= 0` guard clamps backward skew to stale (forcing re-validation) so blast
        // radius is bounded to an extra round-trip vs. bounded staleness — monotonic uptime was
        // rejected because it does not survive relaunches/reboots without persisted anchors.
        guard let date = freshnessDate(familyRecordName: familyRecordName, type: type, scope: scope) else {
            return false
        }
        let interval = Date().timeIntervalSince(date)
        return interval >= 0 && interval <= Self.freshnessMaximumAge
    }

    // WHY: Scope-encapsulated staleness check — loops private/shared internally so Views never import CloudKit or handle CKDatabase.Scope; empty cache is never stale, otherwise at least one authoritative scope is required.
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
}

enum CacheServiceError: Error {
    case inMemoryFallbackFailed
}

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
    } catch { return false }
    let existingRows: [GemLedgerCache]
    do {
        existingRows = try context.fetch(FetchDescriptor<GemLedgerCache>(predicate: #Predicate { $0.profileRecordName == profileRecordName && $0.familyRecordName == familyName }))
    } catch { return false }
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
    } catch { return false }
    return true
}
