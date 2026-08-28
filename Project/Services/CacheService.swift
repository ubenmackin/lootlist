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

@MainActor
@Observable
final class CacheService {
    let container: ModelContainer?
    var initializationError: Error?
    var toastManager: ToastManager?

    /// Single off-main writer for every cache mutation, built from this service's own container so
    /// app-level wiring can hand the same instance to the sync stack.
    private let backgroundWriterLock = Mutex<BackgroundCacheActor?>(nil)
    var backgroundWriter: BackgroundCacheActor? {
        backgroundWriterLock.withLock { $0 }
    }

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "CacheService")
    private var isBatching = false

    #if DEBUG
        @ObservationIgnored
        var ledgerEntryFetchScopes: [String?] = []
    #endif

    @ObservationIgnored private var didSaveTask: Task<Void, Never>?

    var context: ModelContext? {
        container?.mainContext
    }

    let defaults: UserDefaults
    private let inMemory: Bool

    init(inMemory: Bool = false, defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        self.inMemory = inMemory
        let schema = Schema(LootListSchemaV8.models)
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
        if !inMemory, let container {
            Task.detached { [weak self] in
                let writer = await BackgroundCacheActor.makeBackgroundWriter(for: container)
                await MainActor.run { self?.attachBackgroundWriter(writer) }
            }
        }
        installDidSaveObserver()
    }

    /// Attaches a writer created off the main actor. The writer is hoisted as a
    /// long-lived singleton; callers must not recreate it per-call.
    /// WHY: Mutex-protected test-and-set ensures concurrent bootstrap paths never double-assign.
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
        guard !inMemory, !hasBackgroundWriter, let container else { return }
        let writer = await BackgroundCacheActor.makeBackgroundWriter(for: container)
        attachBackgroundWriter(writer)
    }

    private static func errorCategory(_ error: Error) -> String {
        String(describing: type(of: error))
    }

    /// NOTE (WWDC26 / iOS 27 SDK tracking): SwiftData observation bridging for iOS 26 uses
    /// ModelContext.didSave notifications to trigger processPendingChanges on the main context.
    private func installDidSaveObserver() {
        guard container != nil else { return }
        didSaveTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                guard !Task.isCancelled, let self else { break }
                guard let container = self.container else { break }
                // Avoid calling property getters on `notification.object` from @MainActor because accessing properties
                // on a background ModelContext triggers SwiftData concurrency assertions.
                guard let savedObject = notification.object as AnyObject?,
                      savedObject !== (container.mainContext as AnyObject)
                else {
                    continue
                }
                self.refreshMainContextAfterBackgroundSave()
            }
        }
    }

    deinit {
        didSaveTask?.cancel()
    }

    private func refreshMainContextAfterBackgroundSave() {
        guard let container else { return }
        container.mainContext.processPendingChanges()
    }

    func withBatch(_ work: () -> Void) {
        isBatching = true
        defer {
            isBatching = false
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
        guard !isBatching else { return true }
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
    func markCacheFresh(familyRecordName: String, type: CachedRecordType, at date: Date = Date()) {
        defaults.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type))
        for scope in [CKDatabase.Scope.private, .shared] {
            defaults.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
        }
    }

    /// Stamps freshness for record type in the specified database scope.
    func markCacheFresh(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope, at date: Date = Date()) {
        defaults.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
    }

    /// Returns true if a freshness watermark exists for any database scope.
    func isCacheFresh(familyRecordName: String, type: CachedRecordType) -> Bool {
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
        defaults.object(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope)) != nil
    }

    /// Authoritative freshness check: cached data is served only when a freshness watermark exists.
    func isCacheAuthoritative(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope, cachedCount: Int) -> Bool {
        _ = cachedCount // WHY: freshness-only — cachedCount intentionally ignored, stale non-empty must still refetch.
        return isCacheFresh(familyRecordName: familyRecordName, type: type, scope: scope)
    }

    /// Legacy forwarding overload — preserves compatibility while the scope-aware variant is the sole authority.
    /// WHY: Scope-isolated freshness is the only correct check; this forwarding exists only to avoid breaking existing call sites during migration.
    @available(*, deprecated, message: "Use scope-aware isCacheAuthoritative(familyRecordName:type:scope:cachedCount:) — scope-isolated per §2")
    func isCacheAuthoritative(familyRecordName: String, type: CachedRecordType, cachedCount: Int) -> Bool {
        _ = cachedCount // WHY: freshness-only — cachedCount intentionally ignored.
        return isCacheFresh(familyRecordName: familyRecordName, type: type)
    }

    /// Clears freshness watermarks across all scopes for this family and record type.
    func invalidateFreshness(familyRecordName: String, type: CachedRecordType) {
        defaults.removeObject(forKey: freshnessKey(familyRecordName: familyRecordName, type: type))
        for scope in [CKDatabase.Scope.private, .shared] {
            defaults.removeObject(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
        }
    }

    /// Clears freshness watermark for this record type in the specified scope.
    func invalidateFreshness(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope) {
        defaults.removeObject(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
    }

    func invalidateAllFreshness() {
        let staleKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.freshnessKeyPrefix) }
        for key in staleKeys {
            defaults.removeObject(forKey: key)
        }
    }

    func invalidateFreshness(forFamilyRecordName familyRecordName: String) {
        let prefix = "\(Self.freshnessKeyPrefix)\(familyRecordName)_"
        let staleKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
        for key in staleKeys {
            defaults.removeObject(forKey: key)
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

/// Shared gem-credit mutation — single transaction keeps ledger and profile
/// in sync and guarantees idempotency via deterministic ledger recordName.
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
