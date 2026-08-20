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
import Synchronization

@MainActor
@Observable
final class GemService {
    private let cloudKitService: any CloudKitServiceProtocol
    var cacheService: CacheService?
    var toastManager: ToastManager?
    var appState: AppState?
    var syncCoordinator: CKSyncEngineCoordinator?
    var soundManager: SoundManager?

    /// Serializes concurrent gem mutations for the same hero. Two
    /// `creditGems` calls with different `eventKey`s that compute the
    /// balance from `GemLedgerCache` rows concurrently would otherwise
    /// both observe the same pre-credit sum and both upsert the same
    /// `gems` value, losing one ledger's amount from the denormalized
    /// `Profile.gems` field. The same hazard exists between a credit
    /// and a spend on the same profile. Guarding the balance→upsert
    /// section with a per-profile waiter queue mirrors the
    /// `TreasuryService.PeriodMutex` pattern — waiters suspend via
    /// `CheckedContinuation` instead of busy-spinning on `MainActor`.
    private let gemMutationMutex = GemMutex()

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

    func balance(for profileRecordName: String, familyRecordName: String) throws -> Int {
        guard let context = cacheService?.context else { return 0 }
        let descriptor = FetchDescriptor<GemLedgerCache>(predicate: #Predicate {
            $0.profileRecordName == profileRecordName && $0.familyRecordName == familyRecordName
        })
        let entries = try context.fetch(descriptor)
        return entries.reduce(0) { $0 + $1.amount }
    }

    func updateProfile(_ profile: Profile) async throws {
        cacheService?.upsertProfile(profile)
        syncCoordinator?.enqueueSave(recordID: profile.id, isOwner: appState?.isZoneOwner ?? false)
    }

    /// Credits gems with a deterministic ledger ID derived from the triggering
    /// event (`eventKey`) so that re-deliveries (e.g. a cross-device daily-login
    /// claim synced via CloudKit) collapse to a single record — mirroring the
    /// `reward-{completionID}` idempotency pattern used by `RewardEvent`.
    @discardableResult
    func creditGems(amount: Int, to profile: Profile, source: String, eventKey: String, detail: String? = nil) async throws -> Bool {
        guard amount > 0 else { return false }

        // Credits used by the authenticated app must remain in the active
        // profile's family and zone. The nil-appState path is retained for
        // isolated service fixtures that intentionally have no session.
        if let appState {
            try ActiveFamilyScopeGuard.requireAuthenticatedActiveProfile(profile, appState: appState)
            try ActiveFamilyScopeGuard.requireActiveFamilyScope(
                familyRef: profile.family,
                zoneID: profile.id.zoneID,
                appState: appState,
                cloudKit: cloudKitService
            )
        }

        // Serialize concurrent gem mutations for the same hero so two
        // credits with different `eventKey`s (e.g. concurrent daily-login
        // and bonus-objective claims) cannot both read the same
        // pre-credit balance and both upsert `gems = old + amount`,
        // losing one ledger's amount from `Profile.gems`. Uses the
        // per-key waiter queue (`GemMutex`) so contenders suspend via
        // `CheckedContinuation` instead of busy-spinning on `MainActor`.
        let profileKey = profile.id.recordName
        try await gemMutationMutex.lock(key: profileKey)
        defer { gemMutationMutex.unlock(key: profileKey) }

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

        // The deterministic ledger ID is the idempotency key. The existence
        // check and the ledger+profile mutation must be atomic in the same
        // ModelContext transaction; otherwise two concurrent credits for the
        // same logical event (e.g. the same loot drop re-delivered via
        // CKSyncEngine) can both observe `nil` and both enqueue, double-
        // crediting the hero. `CacheService.atomicallyApplyGemCredit` performs
        // the check, derives the new balance from in-memory rows plus the
        // incoming amount, and persists ledger and profile in a single save so
        // a partial failure can never leave them diverged.
        if let cacheService {
            let inserted = cacheService.atomicallyApplyGemCredit(ledger: ledger, to: profile)
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
            // No cache — isolated fixture path without a ModelContext. Cannot
            // enforce local idempotency; preserve the original enqueue+toast so
            // the fixture can still observe the ledger via CloudKit.
            syncCoordinator?.enqueueSave(recordID: ledger.id, isOwner: appState?.isZoneOwner ?? false)
            syncCoordinator?.enqueueSave(recordID: profile.id, isOwner: appState?.isZoneOwner ?? false)
            soundManager?.play(.gemEarned)
            toastManager?.show(message: "+\(amount) Gems! 💎", type: .success)
            return true
        }

        // Enqueue both records atomically for CKSyncEngine.
        syncCoordinator?.enqueueSave(recordID: ledger.id, isOwner: appState?.isZoneOwner ?? false)
        syncCoordinator?.enqueueSave(recordID: profile.id, isOwner: appState?.isZoneOwner ?? false)

        // Play sound & Toast
        soundManager?.play(.gemEarned)
        toastManager?.show(message: "+\(amount) Gems! 💎", type: .success)
        return true
    }

    /// Debits gems for a shop purchase. A caller-provided event key, or the
    /// stable item-based fallback, targets the same ledger row on retries.
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

        // Serialize spend against concurrent credits for the same hero.
        // Uses the per-key waiter queue (`GemMutex`) so contenders
        // suspend via `CheckedContinuation` instead of busy-spinning
        // on `MainActor`.
        let lockKey = spendingProfile.id.recordName
        try await gemMutationMutex.lock(key: lockKey)
        defer { gemMutationMutex.unlock(key: lockKey) }

        let ledgerID = GemLedger.purchaseRecordID(
            profileRecordName: spendingProfile.id.recordName,
            itemID: itemID,
            eventKey: eventKey,
            zoneID: activeFamily
        )

        // Idempotency-first: a retry with the same deterministic ledger ID
        // must succeed without re-debiting, even though the local balance
        // now reflects the first debit. The early balance check below would
        // otherwise see 80 < 120 and incorrectly reject the retry as
        // insufficient. Check the local cache for the ledger before the
        // balance gate; cross-device duplicates are still handled by the
        // server's `atomicallyDebitGems` existing-ledger path.
        if let cacheService,
           cacheService.fetchGemLedger(recordName: ledgerID.recordName, family: spendingProfile.family.recordID.recordName) != nil
        {
            return true
        }

        // Local balance check avoids a wasted server round-trip when the
        // denormalized `Profile.gems` is stale behind the ledger sum.
        // CloudKit remains the authoritative gate via
        // `atomicallyDebitGems`; this is an early local rejection with
        // an explanatory toast.
        if cacheService != nil {
            do {
                let localBalance = try balance(for: spendingProfile.id.recordName, familyRecordName: spendingProfile.family.recordID.recordName)
                if localBalance < amount {
                    toastManager?.show(message: "Insufficient gems 💎", type: .error)
                    return false
                }
            } catch {
                // Balance fetch failure falls through to the server gate.
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

        // A local balance check cannot serialize two devices spending the
        // same gems. CloudKit conditionally saves the current Profile and
        // creates this ledger row atomically; a failed conditional save is
        // retried against the newly authoritative balance.
        guard let debit = try await cloudKitService.atomicallyDebitGems(
            amount: amount,
            from: spendingProfile,
            ledger: ledger
        ) else {
            return false
        }

        cacheService?.applyGemDebit(profile: debit.profile, ledger: debit.ledger)
        syncCoordinator?.enqueueGemDebit(
            profileID: debit.profile.id,
            ledgerID: debit.ledger.id,
            isOwner: appState?.isZoneOwner ?? false
        )

        return true
    }
}

// MARK: - GemMutex

/// Per-key async mutex that serializes callers contending on the same
/// profile record name while allowing different profiles to proceed in
/// parallel. Mirrors `TreasuryService.PeriodMutex` — waiters suspend via
/// `CheckedContinuation` instead of busy-spinning with `Task.yield()` on
/// `MainActor`. Uses `Synchronization.Mutex` to protect the locked-key
/// set and waiter queues so `unlock` can be called synchronously from
/// `defer` inside `creditGems` / `spendGems`.
private final class GemMutex: Sendable {
    private final class Box: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Error>?
    }

    private struct State {
        var locked = Set<String>()
        var waiters: [String: [Box]] = [:]
    }

    private let state = Mutex<State>(State())

    /// Acquires the lock for `key`. If the key is already held, the
    /// caller suspends until the current holder releases it. Ownership
    /// is transferred directly to the next waiter on `unlock`.
    /// The waiter is appended atomically inside the same `withLock` that
    /// decides to wait, closing the TOCTOU between check and enqueue.
    /// Cancellation removes the waiter and resumes throwing
    /// `CancellationError` so a cancelled task never holds the lock.
    func lock(key: String) async throws {
        let box = Box()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.continuation = continuation
                let didAcquire = state.withLock { state -> Bool in
                    if state.locked.contains(key) {
                        state.waiters[key, default: []].append(box)
                        return false
                    }
                    state.locked.insert(key)
                    return true
                }
                if didAcquire {
                    box.continuation = nil
                    continuation.resume()
                }
            }
        }, onCancel: {
            var toResume: CheckedContinuation<Void, Error>?
            state.withLock { state in
                guard var queue = state.waiters[key] else { return }
                if let idx = queue.firstIndex(where: { $0 === box }) {
                    let removed = queue.remove(at: idx)
                    toResume = removed.continuation
                    removed.continuation = nil
                    if queue.isEmpty {
                        state.waiters.removeValue(forKey: key)
                    } else {
                        state.waiters[key] = queue
                    }
                }
            }
            toResume?.resume(throwing: CancellationError())
        })
    }

    /// Releases the lock for `key`, resuming the next waiter if present
    /// and transferring ownership, otherwise clearing the locked flag.
    func unlock(key: String) {
        var next: CheckedContinuation<Void, Error>?
        state.withLock { state in
            if var queue = state.waiters[key], !queue.isEmpty {
                let box = queue.removeFirst()
                next = box.continuation
                box.continuation = nil
                if queue.isEmpty {
                    state.waiters.removeValue(forKey: key)
                } else {
                    state.waiters[key] = queue
                }
                // Ownership stays with the resumed waiter; keep `locked`.
            } else {
                state.locked.remove(key)
            }
        }
        next?.resume()
    }
}
