//
//  TransactionGroupBuilder.swift
//  LootList
//
//  Created by Ben Mackin on 10/20/26.
//

import Foundation

/// Single owner of ledger grouping plus running balances.
enum TransactionGroupBuilder {
    /// MainActor snapshot entry for live cache rows.
    /// WHY snapshot: live @Model rows never cross isolation, so map to value copies before grouping.
    @MainActor static func buildGroups(
        ledgers: [LedgerEntryCache],
        profileRecordName: String
    ) -> [TransactionGroup] {
        guard !profileRecordName.isEmpty else { return [] }
        let owned = ledgers.filter { $0.profileRecordName == profileRecordName }
        guard !owned.isEmpty else { return [] }
        let snapshots = owned.map { TransactionSplit(from: $0) }
        return buildGroups(snapshots: snapshots)
    }

    /// Sendable grouping core operating only on value snapshots.
    nonisolated static func buildGroups(
        snapshots: [TransactionSplit]
    ) -> [TransactionGroup] {
        guard !snapshots.isEmpty else { return [] }

        let goalEntries = snapshots.filter { $0.sourceEnum == .goal }
        // WHY visible-not-counted: legacy nil-bucket rows stay visible while totals stay counted-only.
        let primaries = snapshots.filter { BucketService.isLedgerVisible($0) }

        var buckets: [String: [TransactionSplit]] = [:]
        buckets.reserveCapacity(primaries.count)
        for entry in primaries {
            let key = groupKey(for: entry)
            buckets[key, default: []].append(entry)
        }
        guard !buckets.isEmpty else { return [] }

        struct Draft {
            let groupID: String
            let title: String
            let date: Date
            let totalPennies: Int64
            let splits: [TransactionSplit]
            let goalChildren: [TransactionSplit]
            let source: String
            let isExpandedByDefault: Bool
            let orderedSplits: [TransactionSplit]
            let representativeRecordName: String
        }

        var drafts: [Draft] = []
        drafts.reserveCapacity(buckets.count)
        for (key, entries) in buckets {
            let ordered = entries.sorted {
                if $0.date != $1.date {
                    return $0.date < $1.date
                }
                return $0.recordName < $1.recordName
            }
            let splits = ordered
            let children = goalEntries
                .filter { isGoalChild($0.recordName, for: key) }
                .sorted {
                    if $0.date != $1.date {
                        return $0.date < $1.date
                    }
                    return $0.recordName < $1.recordName
                }
            // WHY single pass: ordered already date-sorted, so min picks the source-invariant representative without a second sort.
            guard let representative = ordered.min(by: { $0.recordName < $1.recordName }) else { continue }
            let rawSource = representative.source
            drafts.append(Draft(
                groupID: key,
                title: baseTitle(for: ordered),
                date: ordered.map(\.date).max() ?? representative.date,
                totalPennies: ordered.filter { BucketService.isCounted($0) }.reduce(into: Int64(0)) { $0 += $1.amount },
                splits: splits,
                goalChildren: children,
                source: rawSource,
                isExpandedByDefault: isExpandedByDefault(for: rawSource),
                orderedSplits: ordered,
                representativeRecordName: representative.recordName
            ))
        }

        // WHY oldest-first: running balances accumulate date ascending then recordName ascending, display reverses after.
        let accumulationOrder = drafts.sorted {
            if $0.date != $1.date {
                return $0.date < $1.date
            }
            return $0.representativeRecordName < $1.representativeRecordName
        }

        struct Accumulated {
            let draft: Draft
            let runningTotal: Int64
            let runningByBucket: [BucketKind: Int64]
        }

        var runningTotal: Int64 = 0
        var balances: [BucketKind: Int64] = [:]
        var withRunnings: [Accumulated] = []
        withRunnings.reserveCapacity(accumulationOrder.count)
        for draft in accumulationOrder {
            for split in draft.orderedSplits {
                // WHY single-count: goal reuse plus transfer moves never inflate the total.
                if BucketService.isCounted(split) {
                    runningTotal += split.amount
                }
                applyAttribution(split, to: &balances)
            }
            withRunnings.append(Accumulated(
                draft: draft,
                runningTotal: runningTotal,
                runningByBucket: balances
            ))
        }

        return withRunnings.map { item in
            TransactionGroup(
                groupID: item.draft.groupID,
                title: item.draft.title,
                date: item.draft.date,
                totalPennies: item.draft.totalPennies,
                runningTotalPennies: item.runningTotal,
                runningByBucket: item.runningByBucket,
                splits: item.draft.splits,
                goalChildren: item.draft.goalChildren,
                source: item.draft.source,
                isExpandedByDefault: item.draft.isExpandedByDefault
            )
        }
        .sorted {
            // WHY mirror accumulation: display inverts date ascending then recordName ascending so equal dates reverse tie-break.
            if $0.date != $1.date {
                return $0.date > $1.date
            }
            return representativeRecordName(for: $0) > representativeRecordName(for: $1)
        }
    }

    /// WHY deterministic tie-break: groups sort by the smallest split recordName so accumulation and display share one key.
    private nonisolated static func representativeRecordName(for group: TransactionGroup) -> String {
        group.splits.map(\.recordName).min() ?? group.groupID
    }

    // MARK: - Attribution

    /// WHY single truth: header tiles and running balances share BucketService attribution over the ledger protocol.
    private nonisolated static func applyAttribution(_ split: TransactionSplit, to balances: inout [BucketKind: Int64]) {
        BucketService.applyBucketAttribution(split, fromBucket: split.fromBucket, to: &balances)
    }

    // MARK: - Group Keys

    private nonisolated static func groupKey(for split: TransactionSplit) -> String {
        groupKey(forRecordName: split.recordName, source: split.sourceEnum)
    }

    private nonisolated static func groupKey(forRecordName recordName: String, source: LedgerSource?) -> String {
        // WHY unified receipt: collision forks append hex-msSuffix layers, so strip before bucket/waterfall logic.
        let deduped = stripCollisionExtension(recordName)
        switch source {
        case .quest, .deposit:
            return stripBucketSuffix(deduped)
        default:
            return waterfallBase(deduped)
        }
    }

    /// WHY single source: waterfall convergence lives in DeterministicRecordID so grouping plus deletes never drift.
    private nonisolated static func waterfallBase(_ recordName: String) -> String {
        DeterministicRecordID.waterfallBase(recordName)
    }

    private nonisolated static func stripBucketSuffix(_ recordName: String) -> String {
        for kind in BucketKind.allCases {
            let suffix = "-\(kind.rawValue)"
            if recordName.hasSuffix(suffix) {
                return String(recordName.dropLast(suffix.count))
            }
        }
        return recordName
    }

    /// WHY single source: collision forks share DeterministicRecordID hex-msSuffix shape, so strip delegates to link extended markers.
    private nonisolated static func stripCollisionExtension(_ recordName: String) -> String {
        DeterministicRecordID.stripCollisionExtension(recordName)
    }

    // MARK: - Presentation

    private nonisolated static func baseTitle(for entries: [TransactionSplit]) -> String {
        let ordered = entries.sorted { $0.recordName < $1.recordName }
        guard let first = ordered.first else { return "" }
        // WHY short type: closed source mapping keeps week parentheticals, dash bucket suffixes, and middle-dot suffixes out of titles.
        switch first.sourceEnum {
        case .quest:
            return "Quest Earnings"
        case .manual:
            return "Spend"
        case .deposit:
            return "Deposit"
        case .withdrawal:
            return "Withdrawal"
        case .transfer:
            return "Transfer"
        case .interest:
            return "Interest"
        case .match:
            return "Match"
        case .purchase:
            return "Purchase"
        case .import:
            return "Import"
        case .goal:
            return "Goal"
        case .none:
            // WHY visible signal: unknown sources surface raw copy so data issues never hide behind Goal.
            let fallback = first.entryDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? "" : fallback
        }
    }

    private nonisolated static func decodedSource(_ raw: String) -> LedgerSource? {
        LedgerSource.decode(raw)
    }

    private nonisolated static func isExpandedByDefault(for rawSource: String) -> Bool {
        // WHY open payouts: split shares plus goal children read as one receipt, singletons stay collapsed.
        switch decodedSource(rawSource) {
        case .quest, .deposit:
            true
        default:
            false
        }
    }

    // MARK: - Quest Week Detail

    /// WHY representative week: split shares share one payout week, so the smallest record owns the Line 2 copy.
    nonisolated static func questWeekDetailText(for group: TransactionGroup) -> String? {
        guard group.sourceEnum == .quest,
              let representative = group.representativeSplit
        else {
            return nil
        }
        // WHY single source: week labels ride WeekMath so minting plus parsing never drift.
        if let label = WeekMath.weekLabel(fromPayoutDescription: representative.entryDescription) {
            return "Payment for week of \(label)"
        }
        // WHY explicit fallback: legacy rows without embedded week copy still require Line 2, so date owns the label.
        return "Payment for week of \(WeekMath.payoutWeekLabel(for: representative.date))"
    }

    // MARK: - Goal Children

    private nonisolated static func candidateBases(for groupKey: String) -> [String] {
        var bases = [groupKey]
        // WHY twin bases: batch mints file under the period while groups key on the payout record.
        if groupKey.hasPrefix("payout-") {
            bases.append(String(groupKey.dropFirst("payout-".count)))
        } else if groupKey.hasPrefix("rt-") {
            bases.append(String(groupKey.dropFirst("rt-".count)))
        }
        return bases
    }

    private nonisolated static func isGoalChild(_ markerRecordName: String, for groupKey: String) -> Bool {
        // WHY single truth: contribution/drawdown identity stays behind shared helpers so groups never drift.
        guard DeterministicRecordID.isContributionRecord(markerRecordName) || GoalService.isDrawdownRecord(markerRecordName) else { return false }
        // WHY dash boundary: goal names may embed base fragments, so only trailing "-base" links.
        // WHY both layers: shared strip peels base-hex and base-hex-msSuffix iteratively so forked drawdowns link.
        for base in candidateBases(for: groupKey) {
            if markerRecordName.hasSuffix("-" + base) {
                return true
            }
            if markerRecordName.hasSuffix("-" + base + "-shortcover") {
                return true
            }
            let stripped = stripCollisionExtension(markerRecordName)
            if stripped != markerRecordName {
                if stripped.hasSuffix("-" + base) {
                    return true
                }
                if stripped.hasSuffix("-" + base + "-shortcover") {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Bucket Filtering

    /// WHY single predicate: one split-level match owns bucket logic so group and filtered receipts never drift.
    private nonisolated static func splitMatchesBucketFilter(_ split: TransactionSplit, filter: BucketKind) -> Bool {
        split.bucketKindEnum == filter || split.fromBucketEnum == filter
    }

    /// WHY single pattern: every ledger surface shares one bucket predicate so transfers read the same everywhere.
    nonisolated static func groupMatchesBucketFilter(_ group: TransactionGroup, filter: BucketKind) -> Bool {
        // WHY both sides: transfers credit the destination while debiting the source, so both buckets claim the group.
        group.splits.contains { splitMatchesBucketFilter($0, filter: filter) }
    }

    /// WHY counted-only: filtered receipts sum counted splits alone so transfer groups total zero like the builder.
    nonisolated static func filteredTotalPennies(for splits: [TransactionSplit]) -> Int64 {
        splits.filter { BucketService.isCounted($0) }.reduce(into: Int64(0)) { $0 += $1.amount }
    }

    /// WHY shared receipt: bucket-filtered groups keep only this bucket's splits with a counted total while running stays builder-owned.
    nonisolated static func filteredGroup(_ group: TransactionGroup, for filter: BucketKind) -> TransactionGroup? {
        let matchingSplits = group.splits.filter { splitMatchesBucketFilter($0, filter: filter) }
        guard !matchingSplits.isEmpty else { return nil }
        let matchingGoals = group.goalChildren.filter { $0.bucketKindEnum == filter }
        if matchingSplits.count == group.splits.count, matchingGoals.count == group.goalChildren.count {
            // WHY identity: full-bucket groups reuse builder running so filter running stays correct.
            return group
        }
        return TransactionGroup(
            groupID: group.groupID,
            title: group.title,
            date: group.date,
            totalPennies: filteredTotalPennies(for: matchingSplits),
            runningTotalPennies: group.runningTotalPennies,
            runningByBucket: group.runningByBucket,
            splits: matchingSplits,
            goalChildren: matchingGoals,
            source: group.source,
            isExpandedByDefault: group.isExpandedByDefault
        )
    }
}
