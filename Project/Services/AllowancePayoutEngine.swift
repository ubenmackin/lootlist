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
        // Symmetric twin of the real-time guard: either settlement already credited
        // this week, so the other must not double-count it. Suffix-aware so split
        // shares (`-{bucket}`) also trip the guard when the payout policy flips mid-week.
        if cachedEntries.contains(where: { $0.recordName == baseRecordName || $0.recordName.hasPrefix("\(baseRecordName)-") }) {
            return
        }
        if cachedEntries.contains(where: { $0.recordName == rtRecordName || $0.recordName.hasPrefix("\(rtRecordName)-") }) {
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

        await mintSplitLedgerEntries(
            SplitMintContext(
                baseRecordName: baseRecordName,
                periodRecordName: periodRecordName,
                amount: amount,
                weekOf: weekOf,
                profile: profile,
                family: family,
                date: date,
                isOwner: isOwner,
                isRealTime: false
            )
        )
    }

    /// WHY context bundle: batch and real-time splits share one mint path; grouping the
    /// inputs keeps the helper signature small while deterministic IDs derive from the same fields.
    struct SplitMintContext {
        let baseRecordName: String
        let periodRecordName: String
        let amount: Double
        let weekOf: Date
        let profile: Profile
        let family: CKRecord.Reference
        let date: Date
        let isOwner: Bool
        let isRealTime: Bool
    }

    /// WHY single helper: batch and real-time splits share one splitPennies mint plus FIFO cascade.
    func mintSplitLedgerEntries(_ context: SplitMintContext) async {
        // WHY whole-penny math: shares sum to the exact settlement total regardless of rounding.
        let totalPennies = Int((context.amount * 100).rounded())
        let receiving = BucketService.splitPennies(totalPennies, profile: context.profile)
            .filter { $0.pennies > 0 }
        guard !receiving.isEmpty else { return }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let zoneID = context.family.recordID.zoneID
        let weekLabel = formatter.string(from: context.weekOf)

        for share in receiving {
            let recordName = receiving.count == 1 ? context.baseRecordName : "\(context.baseRecordName)-\(share.kind.rawValue)"
            let bucketSuffix = receiving.count > 1 ? " · \(share.kind.displayName)" : ""
            let entryDescription = context.isRealTime
                ? "Quest earnings — real-time (week of \(weekLabel))\(bucketSuffix)"
                : "Quest earnings (week of \(weekLabel))\(bucketSuffix)"
            let entry = LedgerEntry(
                profile: CKRecord.Reference(recordID: context.profile.id, action: .none),
                amount: Double(share.pennies) / 100.0,
                description: entryDescription,
                date: context.date,
                source: LedgerSource.quest.rawValue,
                bucketKind: share.kind.rawValue,
                family: context.family,
                id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
            )
            await cacheService.upsertLedgerEntry(entry)
            syncCoordinator.enqueueSave(recordID: entry.id, isOwner: context.isOwner)
        }

        // WHY cascade: save-bucket portions flow into FIFO goals so bucket totals and goal progress agree.
        let saveShares = receiving.filter { $0.kind == .shortTermSave || $0.kind == .longTermSave }
        guard !saveShares.isEmpty else {
            let formatted = CurrencyFormatter.string(context.amount)
            let label = context.isRealTime ? "real-time earnings" : "payout earnings"
            logger.info("Minted \(label) \(formatted, privacy: .public) for period \(context.periodRecordName, privacy: .private)")
            return
        }
        guard let cachedFamily = cacheService.fetchFamily(recordName: context.family.recordID.recordName) else {
            let formatted = CurrencyFormatter.string(context.amount)
            let label = context.isRealTime ? "real-time earnings" : "payout earnings"
            logger.info("Minted \(label) \(formatted, privacy: .public) for period \(context.periodRecordName, privacy: .private)")
            return
        }
        let familyDomain = cachedFamily.toFamily(zoneID: zoneID)

        // WHY sequential fan-out stays on the MainActor so non-Sendable cache never crosses isolation.
        let goalService = GoalService(
            cloudKit: cloudKit,
            cacheService: cacheService,
            appState: appState,
            syncCoordinator: syncCoordinator
        )
        for share in saveShares {
            do {
                _ = try await goalService.contributeToBucket(
                    amountPennies: Int64(share.pennies),
                    profile: context.profile,
                    family: familyDomain,
                    bucketKind: share.kind,
                    sourceEventID: context.periodRecordName,
                    contributionDate: context.date
                )
            } catch {
                logger.warning("Goal allocation failed during payout \(context.periodRecordName, privacy: .private): \(error, privacy: .private)")
            }
        }
        let formatted = CurrencyFormatter.string(context.amount)
        let label = context.isRealTime ? "real-time earnings" : "payout earnings"
        logger.info("Minted \(label) \(formatted, privacy: .public) for period \(context.periodRecordName, privacy: .private)")
    }
}
