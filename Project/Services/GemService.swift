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
    var cacheService: CacheService?
    var toastManager: ToastManager?
    var appState: AppState?
    var syncCoordinator: CKSyncEngineCoordinator?
    var soundManager: SoundManager?

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
    func creditGems(amount: Int, to profile: Profile, source: String, eventKey: String, detail: String? = nil) async throws {
        guard amount > 0 else { return }

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

        // The deterministic ledger ID is the local idempotency key as well as
        // the CloudKit record ID. A retry must not change the profile balance.
        if let cacheService,
           cacheService.fetchGemLedger(recordName: ledgerID.recordName, family: profile.family.recordID.recordName) != nil
        {
            return
        }

        // 1. Optimistic Cache Update
        cacheService?.upsertGemLedger(ledger)

        // 2. Enqueue Sync
        syncCoordinator?.enqueueSave(recordID: ledger.id, isOwner: appState?.isZoneOwner ?? false)

        var updatedProfile = profile
        do {
            updatedProfile.gems = try balance(for: profile.id.recordName, familyRecordName: profile.family.recordID.recordName)
        } catch {
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "GemService")
            logger.warning("GemService.creditGems: failed to compute balance — aborting profile mutation: \(error, privacy: .private)")
            return
        }
        cacheService?.upsertProfile(updatedProfile)
        syncCoordinator?.enqueueSave(recordID: updatedProfile.id, isOwner: appState?.isZoneOwner ?? false)

        // 3. Play sound & Toast
        soundManager?.play(.gemEarned)
        toastManager?.show(message: "+\(amount) Gems! 💎", type: .success)
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
        let ledgerID = GemLedger.purchaseRecordID(
            profileRecordName: spendingProfile.id.recordName,
            itemID: itemID,
            eventKey: eventKey,
            zoneID: activeFamily
        )

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
