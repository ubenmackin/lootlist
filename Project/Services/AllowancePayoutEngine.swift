//
//  AllowancePayoutEngine.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation

/// Bucket-attributed payout settlement for `TreasuryService`. Called from `runPayout` after quest
/// rewards settle: the week's net payout is split by the hero's CURRENT split percentages — read at
extension TreasuryService {
    /// Idempotently mints the ledger entries for one closed weekly payout, split across buckets via
    /// `BucketService.splitPennies`.
    func mintBucketSplitPayout(
        periodRecordName: String,
        amount: Double,
        weekOf: Date,
        profile: Profile?,
        family: CKRecord.Reference,
        date: Date,
        isOwner: Bool
    ) async {
        guard amount > 0 else { return }
        // The split snapshot lives on the hero record; without it there is
        // nothing to attribute against, so fail closed rather than guessing.
        guard let profile else {
            logger.warning("Skipping bucket payout split for \(periodRecordName, privacy: .private): hero profile unresolved")
            return
        }
        let baseRecordName = "payout-\(periodRecordName)"
        let rtRecordName = "rt-\(periodRecordName)"

        let cachedEntries = cacheService.fetchLedgerEntries(
            profileRecordName: profile.id.recordName,
            family: family.recordID.recordName
        )
        if cachedEntries.contains(where: { $0.recordName == baseRecordName }) {
            return
        }
        if cachedEntries.contains(where: { $0.recordName == rtRecordName }) {
            // Defense-in-depth twin of the legacy payout guard: a real-time
            // settlement already credited this week, so the batch split
            // must not double-count it.
            return
        }

        if let cachedPeriod = cacheService.fetchAllowancePeriod(recordName: periodRecordName, family: family.recordID.recordName) {
            guard cachedPeriod.statusEnum == .paid, abs((cachedPeriod.paidAmount ?? 0.0) - amount) < 0.001 else {
                logger.warning("Skipping bucket payout split: period \(periodRecordName) status is not paid or amount mismatch")
                return
            }
        }

        // Whole-penny math keeps the bucket entries summing to the exact
        // payout total regardless of how percentages round.
        let totalPennies = Int((amount * 100).rounded())
        let receiving = BucketService.splitPennies(totalPennies, profile: profile)
            .filter { $0.pennies > 0 }
        guard !receiving.isEmpty else { return }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let zoneID = family.recordID.zoneID

        for share in receiving {
            let recordName = receiving.count == 1 ? baseRecordName : "\(baseRecordName)-\(share.kind.rawValue)"
            let bucketSuffix = receiving.count > 1 ? " · \(share.kind.displayName)" : ""
            let entryDescription = "Quest earnings (week of \(formatter.string(from: weekOf)))\(bucketSuffix)"
            let entry = LedgerEntry(
                profile: CKRecord.Reference(recordID: profile.id, action: .none),
                amount: Double(share.pennies) / 100.0,
                description: entryDescription,
                date: date,
                source: LedgerSource.quest.rawValue,
                bucketKind: share.kind.rawValue,
                family: family,
                id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
            )
            await cacheService.upsertLedgerEntry(entry)
            syncCoordinator.enqueueSave(recordID: entry.id, isOwner: isOwner)
        }

        // Fan out save-bucket portions to FIFO goals concurrently. Each
        // contributeToBucket call coalesces its N allocations + M completions
        // into a single saveContext, so withThrowingTaskGroup avoids serial
        // N+M saves across buckets.
        let saveShares = receiving.filter { $0.kind == .shortTermSave || $0.kind == .longTermSave }
        guard !saveShares.isEmpty else { return }
        guard let cachedFamily = cacheService.fetchFamily(recordName: family.recordID.recordName) else { return }
        let familyDomain = cachedFamily.toFamily(zoneID: zoneID)

        // Captured MainActor-isolated dependencies before fan-out: child tasks run
        // off the MainActor and GoalService's initializer is MainActor-isolated,
        // so both the property reads and the init require await inside the group.
        let capturedCloudKit = self.cloudKit
        let capturedCacheService = self.cacheService
        let capturedAppState = self.appState
        let capturedSyncCoordinator = self.syncCoordinator

        await withThrowingTaskGroup(of: Void.self) { group in
            for share in saveShares {
                group.addTask {
                    let goalService = await GoalService(
                        cloudKit: capturedCloudKit,
                        cacheService: capturedCacheService,
                        appState: capturedAppState,
                        syncCoordinator: capturedSyncCoordinator
                    )
                    _ = try await goalService.contributeToBucket(
                        amountPennies: Int64(share.pennies),
                        profile: profile,
                        family: familyDomain,
                        bucketKind: share.kind,
                        sourceEventID: periodRecordName,
                        contributionDate: date
                    )
                }
            }
            do {
                try await group.waitForAll()
            } catch {
                logger.warning("Goal allocation failed during payout \(periodRecordName, privacy: .private): \(error, privacy: .private)")
            }
        }
    }
}
