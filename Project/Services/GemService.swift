//
//  GemService.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import Foundation
import os
import SwiftData

@MainActor
@Observable
final class GemService {
    private let cloudKitService: any CloudKitServiceProtocol
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "GemService")
    var cacheService: CacheService?
    var toastManager: ToastManager?
    var appState: AppState?
    var syncCoordinator: CKSyncEngineCoordinator?
    var soundManager: SoundManager?

    /// Serializes concurrent gem mutations for the same hero via `GemLock`.
    private let gemLock = GemLock()

    init(cloudKitService: any CloudKitServiceProtocol,
         cacheService: CacheService? = nil,
         toastManager: ToastManager? = nil,
         appState: AppState? = nil,
         syncCoordinator: CKSyncEngineCoordinator? = nil,
         soundManager: SoundManager? = nil)
    {
        self.cloudKitService = cloudKitService
        self.cacheService = cacheService
        self.toastManager = toastManager
        self.appState = appState
        self.syncCoordinator = syncCoordinator
        self.soundManager = soundManager
    }

    // MARK: - Balance

    func balance(for profileRecordName: String, familyRecordName: String) throws -> Int {
        guard let context = cacheService?.context else { return 0 }
        let descriptor = FetchDescriptor<GemLedgerCache>(predicate: #Predicate {
            $0.profileRecordName == profileRecordName && $0.familyRecordName == familyRecordName
        })
        let entries = try context.fetch(descriptor)
        return entries.reduce(0) { $0 + $1.amount }
    }

    func updateProfile(_ profile: Profile) async throws {
        await cacheService?.upsertProfile(profile)
        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let storedOwner = appState?.isZoneOwner ?? false
        if isOwner != storedOwner {
            logger.warning("GemService.updateProfile isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
        syncCoordinator?.enqueueSave(recordID: profile.id, isOwner: isOwner)
    }

    // MARK: - Credit & Spend

    /// Credits gems using deterministic ledger IDs for idempotent cross-device syncing.
    @discardableResult
    func creditGems(amount: Int, to profile: Profile, source: String, eventKey: String, detail: String? = nil) async throws -> Bool {
        guard amount > 0 else { return false }

        if let appState {
            do {
                try ActiveFamilyScopeGuard.requireAuthenticatedActiveProfile(profile, appState: appState)
                try ActiveFamilyScopeGuard.requireActiveFamilyScope(
                    familyRef: profile.family,
                    zoneID: profile.id.zoneID,
                    appState: appState,
                    cloudKit: cloudKitService
                )
            } catch let error as ScopeViolation {
                if case .noActiveProfile = error {
                    let activeFamilyName = appState.family?.id.recordName ?? appState.currentProfile?.family.recordID.recordName
                    if let activeFamilyName, profile.family.recordID.recordName == activeFamilyName {
                        // Hero family scoping is valid — allow local-first credit even when
                        // authStatus has not yet reached .authenticated (cold launch / test).
                    } else {
                        throw error
                    }
                } else {
                    throw error
                }
            }
        }

        let profileKey = profile.id.recordName
        return await gemLock.withLock(key: profileKey) {
            let activeFamily = profile.id.zoneID

            let ledgerID = GemLedger.deterministicRecordID(
                profileRecordName: profile.id.recordName,
                eventKey: eventKey,
                source: source,
                zoneID: activeFamily
            )

            let ledger = GemLedger(
                profileRecordName: profile.id.recordName,
                family: profile.family,
                amount: amount,
                source: source,
                sourceDetail: detail,
                createdAt: Date(),
                id: ledgerID
            )

            // MARK: - Atomic idempotency and balance update

            // Deterministic ledger ID ensures gem credits are processed exactly once.
            if let cacheService {
                let inserted = await cacheService.atomicallyApplyGemCredit(ledger: ledger, to: profile)
                if !inserted {
                    // `false` covers both "already existed" (idempotent retry) and
                    // "save failed". Re-check to distinguish: an existing row means
                    // the duplicate was correctly collapsed.
                    if cacheService.fetchGemLedger(recordName: ledgerID.recordName, family: profile.family.recordID.recordName) != nil {
                        return false
                    }
                    return false
                }
            } else {
                // Direct CloudKit save fallback when running without a local cache context.
                let isOwnerFallback = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
                let storedOwnerFallback = appState?.isZoneOwner ?? false
                if isOwnerFallback != storedOwnerFallback {
                    logger.warning("GemService.creditGems fallback isOwner corrected via creator anchor: stored=\(storedOwnerFallback) resolved=\(isOwnerFallback)")
                }
                syncCoordinator?.enqueueSave(recordID: ledger.id, isOwner: isOwnerFallback)
                syncCoordinator?.enqueueSave(recordID: profile.id, isOwner: isOwnerFallback)
                soundManager?.play(.gemEarned)
                toastManager?.show(message: "+\(amount) Gems! 💎", type: .success)
                return true
            }

            // Enqueue both records atomically for CKSyncEngine.
            // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
            let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
            let storedOwner = appState?.isZoneOwner ?? false
            if isOwner != storedOwner {
                logger.warning("GemService.creditGems isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
            }
            syncCoordinator?.enqueueSave(recordID: ledger.id, isOwner: isOwner)
            syncCoordinator?.enqueueSave(recordID: profile.id, isOwner: isOwner)

            // Play sound & Toast
            var updatedProfile = profile
            do {
                updatedProfile.gems = try balance(for: profile.id.recordName, familyRecordName: profile.family.recordID.recordName)
            } catch {
                logger.warning("GemService.creditGems: failed to compute balance — aborting profile mutation: \(error, privacy: .private)")
                return false
            }
            await cacheService?.upsertProfile(updatedProfile)
            // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
            let isOwnerUpdated = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
            let storedOwnerUpdated = appState?.isZoneOwner ?? false
            if isOwnerUpdated != storedOwnerUpdated {
                logger.warning("GemService.creditGems updatedProfile isOwner corrected via creator anchor: stored=\(storedOwnerUpdated) resolved=\(isOwnerUpdated)")
            }
            syncCoordinator?.enqueueSave(recordID: updatedProfile.id, isOwner: isOwnerUpdated)

            soundManager?.play(.gemEarned)
            toastManager?.show(message: "+\(amount) Gems! 💎", type: .success)
            return true
        }
    }

    /// Debits gems for a shop purchase.
    func spendGems(
        amount: Int,
        from profile: Profile,
        itemID: String,
        on item: String,
        eventKey: String? = nil
    ) async throws -> Bool {
        guard amount > 0 else { return false }

        let activeFamily = cloudKitService.activeFamilyZoneID ?? profile.family.recordID.zoneID
        let spendingProfile = cacheService?.fetchProfile(
            recordName: profile.id.recordName,
            family: profile.family.recordID.recordName
        )?.toProfile(zoneID: activeFamily) ?? profile

        let lockKey = spendingProfile.id.recordName
        return try await gemLock.withLock(key: lockKey) {
            let ledgerID = GemLedger.purchaseRecordID(
                profileRecordName: spendingProfile.id.recordName,
                itemID: itemID,
                eventKey: eventKey,
                zoneID: activeFamily
            )

            // Check local cache for existing ledger entry to ensure idempotent retries succeed.
            if let cacheService,
               cacheService.fetchGemLedger(recordName: ledgerID.recordName, family: spendingProfile.family.recordID.recordName) != nil
            {
                return true
            }

            // Checks local gem balance before making server requests.
            if cacheService != nil {
                do {
                    let localBalance = try balance(for: spendingProfile.id.recordName, familyRecordName: spendingProfile.family.recordID.recordName)
                    if localBalance < amount {
                        toastManager?.show(message: "Insufficient gems 💎", type: .error)
                        return false
                    }
                } catch {
                    logger.debug("Local gem balance fetch failed: \(error, privacy: .private); falling through to server gate")
                }
            }

            let ledger = GemLedger(
                profileRecordName: spendingProfile.id.recordName,
                family: spendingProfile.family,
                amount: -amount,
                source: "shopPurchase",
                sourceDetail: item,
                createdAt: Date(),
                id: ledgerID
            )

            guard let debit = try await cloudKitService.atomicallyDebitGems(
                amount: amount,
                from: spendingProfile,
                ledger: ledger
            ) else {
                return false
            }

            await cacheService?.applyGemDebit(profile: debit.profile, ledger: debit.ledger)
            // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
            let isOwnerDebit = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
            let storedOwnerDebit = appState?.isZoneOwner ?? false
            if isOwnerDebit != storedOwnerDebit {
                logger.warning("GemService.spendGems isOwner corrected via creator anchor: stored=\(storedOwnerDebit) resolved=\(isOwnerDebit)")
            }
            syncCoordinator?.enqueueGemDebit(
                profileID: debit.profile.id,
                ledgerID: debit.ledger.id,
                isOwner: isOwnerDebit
            )

            return true
        }
    }
}

// MARK: - GemLock

/// Serializes concurrent gem operations on the same key.
actor GemLock {
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
        // resumes exactly once — actor-isolated, no onCancel needed
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
