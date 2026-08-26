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

@MainActor
@Observable
final class CacheService {
    let container: ModelContainer?
    var initializationError: Error?
    var toastManager: ToastManager?

    /// Single off-main writer for every cache mutation, built from this
    /// service's own container so app-level wiring can hand the same instance
    /// to the sync stack. Nil for in-memory stores (unit/UI tests), where
    /// mutations fall back to the retained main-actor bodies and stay
    /// synchronous.
    let backgroundWriter: BackgroundCacheActor?

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

    init(inMemory: Bool = false, defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
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
        // In-memory stores keep main-actor writes so test seeding and
        // assertions stay synchronous.
        backgroundWriter = (!inMemory ? container : nil).map { BackgroundCacheActor(container: $0) }
        installDidSaveObserver()
    }

    private static func errorCategory(_ error: Error) -> String {
        String(describing: type(of: error))
    }

    private func installDidSaveObserver() {
        guard container != nil else { return }
        didSaveTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                guard !Task.isCancelled, let self else { break }
                guard let container = self.container else { break }
                // Avoid calling property getters on `notification.object` from @MainActor
                // because accessing properties on a background ModelContext triggers SwiftData
                // concurrency assertions. Pure pointer identity with `mainContext` safely
                // distinguishes background saves from main-context saves.
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

    /// Legacy stamp (no scope) — prefer scope-aware overload; scope-isolated so private-only pass never satisfies shared reads (§2, CachedRecordType.fetchScopes,
    /// completeSyncPass).
    func markCacheFresh(familyRecordName: String, type: CachedRecordType, at date: Date = Date()) {
        defaults.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type))
    }

    /// Stamps freshness for `type` in `scope`. Scope-isolated: private-only sync must not satisfy shared-DB reads (§2, CachedRecordType.fetchScopes, completeSyncPass gating).
    func markCacheFresh(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope, at date: Date = Date()) {
        defaults.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
    }

    /// Legacy check (legacy OR any scope). Prefer scope-aware overload — scope-isolated reads must use `isCacheFresh(scope:)` so private-only never satisfies shared (§2,
    /// fetchScopes).
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

    /// Returns true if `scope` was stamped or if global legacy watermark was stamped.
    func isCacheFresh(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope) -> Bool {
        let legacyKey = freshnessKey(familyRecordName: familyRecordName, type: type)
        if defaults.object(forKey: legacyKey) != nil {
            return true
        }
        return defaults.object(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope)) != nil
    }

    /// Invalidates legacy + both scopes. Scope-isolated — clears private/shared watermarks together (§2, CachedRecordType.fetchScopes).
    func invalidateFreshness(familyRecordName: String, type: CachedRecordType) {
        defaults.removeObject(forKey: freshnessKey(familyRecordName: familyRecordName, type: type))
        for scope in [CKDatabase.Scope.private, .shared] {
            defaults.removeObject(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
        }
    }

    /// Invalidates freshness for `type` in `scope` only. Scope-isolated — removing private must not affect shared (§2, CachedRecordType.fetchScopes).
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
