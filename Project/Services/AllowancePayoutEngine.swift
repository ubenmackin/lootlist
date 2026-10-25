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
        amount: Int64,
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
        let baseRecordName = DeterministicRecordID.payout(periodRecordName: periodRecordName)
        let rtRecordName = DeterministicRecordID.realtimePayout(periodRecordName: periodRecordName)

        let cachedEntries = cacheService.fetchLedgerEntries(
            profileRecordName: profile.id.recordName,
            family: family.recordID.recordName
        )
        if cachedEntries.contains(where: { $0.recordName == rtRecordName || $0.recordName.hasPrefix("\(rtRecordName)-") }) {
            // Defense-in-depth twin of the legacy payout guard: a real-time
            // settlement already credited this week, so the batch split
            // must not double-count it.
            return
        }

        if let cachedPeriod = cacheService.fetchAllowancePeriod(recordName: periodRecordName, family: family.recordID.recordName) {
            if cachedPeriod.statusEnum != .paid || (cachedPeriod.paidAmount ?? 0) != amount {
                logger.warning("Bucket payout split mismatch for \(periodRecordName): re-reading before abort")
                // WHY re-read: cache write may lag the runPayout upsert, so retry once before aborting.
                let retried = cacheService.fetchAllowancePeriod(recordName: periodRecordName, family: family.recordID.recordName)
                guard let retried, retried.statusEnum == .paid, (retried.paidAmount ?? 0) == amount else {
                    logger.error("Bucket payout split aborted for \(periodRecordName): period not paid or amount mismatch after retry")
                    return
                }
            }
        } else {
            logger.warning("Bucket payout split period missing for \(periodRecordName): re-reading before abort")
            // WHY re-read: family-scoped fetch may miss on first read, so retry once before aborting.
            guard let retried = cacheService.fetchAllowancePeriod(recordName: periodRecordName, family: family.recordID.recordName),
                  retried.statusEnum == .paid, (retried.paidAmount ?? 0) == amount
            else {
                logger.error("Bucket payout split aborted for \(periodRecordName): period missing or mismatched after retry")
                return
            }
        }

        let existing = cachedEntries.filter {
            $0.recordName == baseRecordName || $0.recordName.hasPrefix("\(baseRecordName)-")
        }
        if !existing.isEmpty {
            // WHY deduped total: duplicate twins would otherwise double-count and suppress the delta.
            let settledTotal = accumulateBucket(existing, baseRecordName: baseRecordName).totals.values.reduce(Int64(0), +)
            let zoneID = family.recordID.zoneID
            // WHY single source: week labels ride WeekMath so minting plus parsing never drift.
            let weekLabel = WeekMath.payoutWeekLabel(for: weekOf)
            guard amount > settledTotal else {
                // WHY converge without mint: zero-delta re-runs still collapse twins so later deltas measure clean totals.
                await convergeDuplicateTwins(
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
                    ),
                    existing: existing,
                    zoneID: zoneID,
                    weekLabel: weekLabel
                )
                return
            }
            let delta = amount - settledTotal
            await mintBatchSupplemental(
                SplitMintContext(
                    baseRecordName: baseRecordName,
                    periodRecordName: periodRecordName,
                    amount: delta,
                    weekOf: weekOf,
                    profile: profile,
                    family: family,
                    date: date,
                    isOwner: isOwner,
                    isRealTime: false
                ),
                existing: existing,
                zoneID: zoneID,
                weekLabel: weekLabel
            )
            return
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
        let amount: Int64
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
        let totalPennies = context.amount
        let receiving = BucketService.splitPennies(totalPennies, profile: context.profile)
            .filter { $0.pennies > 0 }
        guard !receiving.isEmpty else { return }
        let zoneID = context.family.recordID.zoneID
        // WHY single source: week labels ride WeekMath so minting plus parsing never drift.
        let weekLabel = WeekMath.payoutWeekLabel(for: context.weekOf)
        if context.isRealTime {
            await mintRealTimeDelta(context, receiving: receiving, zoneID: zoneID, weekLabel: weekLabel)
        } else {
            await mintBatchShares(context, receiving: receiving, zoneID: zoneID, weekLabel: weekLabel)
        }
    }

    /// WHY twin key: explicit attribution wins over inferred suffix so merges never lose funds.
    private func bucketKey(for twin: LedgerEntryCache, baseRecordName: String) -> String {
        if let kind = twin.bucketKind, !kind.isEmpty {
            return kind
        }
        let prefix = "\(baseRecordName)-"
        if twin.recordName.hasPrefix(prefix) {
            return String(twin.recordName.dropFirst(prefix.count))
        }
        return BucketKind.spend.rawValue
    }

    /// WHY single pass: totals and name sets derive together so convergence sees one snapshot.
    private func accumulateBucket(
        _ twins: [LedgerEntryCache],
        baseRecordName: String
    ) -> (totals: [String: Int64], names: [String: [String]]) {
        var totals: [String: Int64] = [:]
        var names: [String: [String]] = [:]
        for twin in twins {
            let key = bucketKey(for: twin, baseRecordName: baseRecordName)
            totals[key, default: 0] += twin.amount
            names[key, default: []].append(twin.recordName)
        }
        return (totals, names)
    }

    /// WHY suffix wins: explicit bucket attribution survives base/suffix duplication without losing funds.
    private func expectedShareNames(
        _ allNames: [String: [String]],
        baseRecordName: String
    ) -> [String: String] {
        var primary: [String: String] = [:]
        for (key, names) in allNames {
            guard let first = names.first else { continue }
            if names.count == 1 {
                primary[key] = first
                continue
            }
            let suffixed = "\(baseRecordName)-\(key)"
            primary[key] = names.contains(suffixed) ? suffixed : first
        }
        return primary
    }

    /// WHY incremental delta: new money only so current split never rebases prior attribution.
    private func mintRealTimeDelta(
        _ context: SplitMintContext,
        receiving: [BucketService.BucketShare],
        zoneID: CKRecordZone.ID,
        weekLabel: String
    ) async {
        let familyName = context.family.recordID.recordName
        let profileName = context.profile.id.recordName
        let existing = cacheService.fetchLedgerEntries(profileRecordName: profileName, family: familyName)
            .filter {
                $0.recordName == context.baseRecordName
                    || $0.recordName.hasPrefix("\(context.baseRecordName)-")
            }
        await mintCumulativeSupplemental(
            context,
            receiving: receiving,
            existing: existing,
            zoneID: zoneID,
            weekLabel: weekLabel
        )
    }

    /// WHY cumulative batch: supplemental earnings add to stable IDs so retries converge.
    private func mintBatchSupplemental(
        _ context: SplitMintContext,
        existing: [LedgerEntryCache],
        zoneID: CKRecordZone.ID,
        weekLabel: String
    ) async {
        let receiving = BucketService.splitPennies(context.amount, profile: context.profile)
            .filter { $0.pennies > 0 }
        guard !receiving.isEmpty else { return }
        await mintCumulativeSupplemental(
            context,
            receiving: receiving,
            existing: existing,
            zoneID: zoneID,
            weekLabel: weekLabel
        )
    }

    /// WHY single converge path: batch supplemental and real-time deltas share one cumulative
    /// apply-merge-prune-cascade so attribution never drifts between entry points.
    private func mintCumulativeSupplemental(
        _ context: SplitMintContext,
        receiving: [BucketService.BucketShare],
        existing: [LedgerEntryCache],
        zoneID: CKRecordZone.ID,
        weekLabel: String
    ) async {
        let accumulated = accumulateBucket(existing, baseRecordName: context.baseRecordName)
        var primary = expectedShareNames(accumulated.names, baseRecordName: context.baseRecordName)
        var totals = accumulated.totals
        var expected = Set(primary.values)
        let deltaKinds = Set(receiving.map(\.kind.rawValue))
        await applyCumulativeShares(
            context,
            receiving: receiving,
            existing: existing,
            primary: &primary,
            totals: &totals,
            expected: &expected,
            zoneID: zoneID,
            weekLabel: weekLabel
        )
        await mergeDuplicateTwins(
            context,
            allNames: accumulated.names,
            primary: primary,
            totals: totals,
            deltaKinds: deltaKinds,
            zoneID: zoneID,
            weekLabel: weekLabel
        )
        await pruneStaleTwins(
            existing,
            expected: expected,
            familyName: context.family.recordID.recordName,
            zoneID: zoneID
        )
        await cascadeDelta(context, shares: receiving, zoneID: zoneID)
    }

    /// WHY converge without mint: zero-delta re-runs still collapse twins so later deltas measure clean totals.
    private func convergeDuplicateTwins(
        _ context: SplitMintContext,
        existing: [LedgerEntryCache],
        zoneID: CKRecordZone.ID,
        weekLabel: String
    ) async {
        let accumulated = accumulateBucket(existing, baseRecordName: context.baseRecordName)
        let primary = expectedShareNames(accumulated.names, baseRecordName: context.baseRecordName)
        let expected = Set(primary.values)
        await mergeDuplicateTwins(
            context,
            allNames: accumulated.names,
            primary: primary,
            totals: accumulated.totals,
            deltaKinds: [],
            zoneID: zoneID,
            weekLabel: weekLabel
        )
        await pruneStaleTwins(
            existing,
            expected: expected,
            familyName: context.family.recordID.recordName,
            zoneID: zoneID
        )
    }

    /// WHY cumulative write: prior total plus delta keeps mid-week split changes additive.
    private func applyCumulativeShares(
        _ context: SplitMintContext,
        receiving: [BucketService.BucketShare],
        existing: [LedgerEntryCache],
        primary: inout [String: String],
        totals: inout [String: Int64],
        expected: inout Set<String>,
        zoneID: CKRecordZone.ID,
        weekLabel: String
    ) async {
        // WHY derive emptiness: caller snapshot is the source so single-bucket base naming never drifts.
        let isExistingEmpty = existing.isEmpty
        for share in receiving {
            let key = share.kind.rawValue
            let target: String
            let newTotal: Int64
            if let current = primary[key] {
                target = current
                newTotal = (totals[key] ?? 0) + share.pennies
            } else if isExistingEmpty, receiving.count == 1 {
                target = context.baseRecordName
                newTotal = share.pennies
            } else {
                target = "\(context.baseRecordName)-\(key)"
                newTotal = share.pennies
            }
            expected.insert(target)
            primary[key] = target
            totals[key] = newTotal
            await upsertPayoutEntry(
                context,
                recordName: target,
                totalPennies: newTotal,
                kind: share.kind,
                weekLabel: weekLabel,
                zoneID: zoneID,
                isRealTime: context.isRealTime
            )
        }
    }

    /// WHY merge-then-prune: duplicate twins for one bucket converge before stale rows clear.
    private func mergeDuplicateTwins(
        _ context: SplitMintContext,
        allNames: [String: [String]],
        primary: [String: String],
        totals: [String: Int64],
        deltaKinds: Set<String>,
        zoneID: CKRecordZone.ID,
        weekLabel: String
    ) async {
        for (key, names) in allNames where !deltaKinds.contains(key) && names.count > 1 {
            guard let target = primary[key], let total = totals[key], let kind = BucketKind(rawValue: key) else { continue }
            await upsertPayoutEntry(
                context,
                recordName: target,
                totalPennies: total,
                kind: kind,
                weekLabel: weekLabel,
                zoneID: zoneID,
                isRealTime: context.isRealTime
            )
        }
    }

    /// WHY prune stale twins: share-count shifts leave doubles that would double-count without cleanup.
    private func pruneStaleTwins(
        _ existing: [LedgerEntryCache],
        expected: Set<String>,
        familyName: String,
        zoneID: CKRecordZone.ID
    ) async {
        let stale = existing.filter { !expected.contains($0.recordName) }
        for twin in stale {
            // WHY single step: tombstone is captured inside the helper so the delete survives row removal.
            await ActiveFamilyScopeGuard.deleteAndEnqueue(
                cacheService: cacheService,
                target: .init(recordID: CKRecord.ID(recordName: twin.recordName, zoneID: zoneID), familyRecordName: familyName),
                type: .ledgerEntry,
                deleteContext: .init(
                    coordinator: syncCoordinator,
                    appState: appState,
                    logger: logger,
                    context: "TreasuryService.pruneStaleTwins",
                    expectedActiveZone: appState.familyZoneID
                )
            )
        }
    }

    /// WHY single mint: deterministic IDs converge across retries without duplicates.
    private func upsertPayoutEntry(
        _ context: SplitMintContext,
        recordName: String,
        totalPennies: Int64,
        kind: BucketKind,
        weekLabel: String,
        zoneID: CKRecordZone.ID,
        isRealTime: Bool
    ) async {
        let isSuffixed = recordName != context.baseRecordName
        // WHY single source: payout copy rides WeekMath so minting plus parsing never drift.
        let description = WeekMath.payoutDescription(
            weekLabel: weekLabel,
            bucketDisplayName: isSuffixed ? kind.displayName : nil,
            isRealTime: isRealTime
        )
        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: context.profile.id, action: .none),
            amount: totalPennies,
            description: description,
            date: context.date,
            source: LedgerSource.quest.rawValue,
            bucketKind: kind.rawValue,
            family: context.family,
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
        await cacheService.upsertLedgerEntry(entry)
        syncCoordinator.enqueueSave(recordID: entry.id, isOwner: context.isOwner)
    }

    /// WHY future-only split: current percentages attribute new money without rebasing prior weeks.
    private func mintBatchShares(
        _ context: SplitMintContext,
        receiving: [BucketService.BucketShare],
        zoneID: CKRecordZone.ID,
        weekLabel: String
    ) async {
        for share in receiving {
            let recordName = receiving.count == 1
                ? context.baseRecordName
                : "\(context.baseRecordName)-\(share.kind.rawValue)"
            await upsertPayoutEntry(
                context,
                recordName: recordName,
                totalPennies: share.pennies,
                kind: share.kind,
                weekLabel: weekLabel,
                zoneID: zoneID,
                isRealTime: false
            )
        }
        await cascadeDelta(context, shares: receiving, zoneID: zoneID)
    }

    /// WHY cascade: save-bucket portions flow into FIFO goals so bucket totals and goal progress agree.
    private func cascadeDelta(
        _ context: SplitMintContext,
        shares: [BucketService.BucketShare],
        zoneID: CKRecordZone.ID
    ) async {
        let saveShares = shares.filter { $0.kind == .shortTermSave || $0.kind == .longTermSave }
        let label = context.isRealTime ? "real-time earnings" : "payout earnings"
        guard !saveShares.isEmpty, let cachedFamily = cacheService.fetchFamily(recordName: context.family.recordID.recordName) else {
            let formatted = CurrencyFormatter.string(pennies: context.amount)
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
                    amountPennies: share.pennies,
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
        let formatted = CurrencyFormatter.string(pennies: context.amount)
        logger.info("Minted \(label) \(formatted, privacy: .public) for period \(context.periodRecordName, privacy: .private)")
    }
}
