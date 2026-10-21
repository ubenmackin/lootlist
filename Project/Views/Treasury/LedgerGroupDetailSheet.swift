//
//  LedgerGroupDetailSheet.swift
//  LootList
//
//  Created by Ben Mackin on 10/20/26.
//

import SwiftUI

/// Single owner of expanded audit copy for a grouped ledger row.
struct LedgerGroupDetailSheet: View {
    let group: TransactionGroup
    let selectedBucketFilter: BucketKind?
    /// Display mapping from goal record name to GoalCache name.
    let goalNames: [String: String]
    /// Archived goal identities stay non-tappable.
    let archivedGoalIDs: Set<String>
    /// Host-owned tap handler; nil blocks navigation fail-closed.
    let onGoalTap: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss

    init(
        group: TransactionGroup,
        selectedBucketFilter: BucketKind? = nil,
        goalNames: [String: String] = [:],
        archivedGoalIDs: Set<String> = [],
        onGoalTap: ((String) -> Void)? = nil
    ) {
        self.group = group
        self.selectedBucketFilter = selectedBucketFilter
        self.goalNames = goalNames
        self.archivedGoalIDs = archivedGoalIDs
        self.onGoalTap = onGoalTap
    }

    private var sortedSplits: [TransactionSplit] {
        // WHY receipt order: splits stack Spend then Short then Long so bucket columns read consistently.
        group.splits.sorted {
            let lhsKeys = sortKeys(for: $0)
            let rhsKeys = sortKeys(for: $1)
            if lhsKeys.0 != rhsKeys.0 {
                return lhsKeys.0 < rhsKeys.0
            }
            if lhsKeys.1 != rhsKeys.1 {
                return lhsKeys.1 < rhsKeys.1
            }
            return $0.recordName < $1.recordName
        }
    }

    private func sortKeys(for split: TransactionSplit) -> (Int, Int) {
        // WHY source-first: transfers need from-then-to ordering so both legs read consistently.
        if split.sourceEnum == .transfer {
            return (bucketOrderKey(for: split.fromBucketEnum), bucketOrderKey(for: split.toBucketEnum ?? split.bucketKindEnum))
        }
        let key = bucketOrderKey(for: split.bucketKindEnum ?? split.fromBucketEnum ?? split.toBucketEnum)
        return (key, key)
    }

    private func bucketOrderKey(for kind: BucketKind?) -> Int {
        switch kind {
        case .spend:
            0
        case .shortTermSave:
            1
        case .longTermSave:
            2
        case nil:
            3
        }
    }

    private var isNetZeroTransfer: Bool {
        group.totalPennies == 0 && group.sourceEnum == .transfer
    }

    private var shouldHideMovement: Bool {
        group.splits.count <= 1 && group.goalChildren.isEmpty && group.sourceEnum != .transfer
    }

    private var representativeSplit: TransactionSplit? {
        group.representativeSplit
    }

    private var detailWhat: String? {
        // WHY spend-only: manual spends alone carry what-where copy, other sources would misread.
        guard group.sourceEnum == .manual, let representative = representativeSplit else { return nil }
        let what = representative.entryDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !what.isEmpty else { return nil }
        return what
    }

    private var detailWhere: String? {
        // WHY separate Where: location renders as its own pair so What stays clean without concatenation.
        guard group.sourceEnum == .manual, let representative = representativeSplit else { return nil }
        let whereText = (representative.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whereText.isEmpty else { return nil }
        return whereText
    }

    private var questWeekDetailText: String? {
        // WHY builder-owned: week copy lives in the builder so sheet plus rows never drift.
        TransactionGroupBuilder.questWeekDetailText(for: group)
    }

    // MARK: - Goal Identity

    /// Resolves the owning goal record name for a contribution marker.
    /// WHY longest-first: goal IDs nest by prefix, so specific wins deterministically.
    private func goalRecordName(for markerRecordName: String) -> String? {
        for key in goalNames.keys.sorted(by: { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs < rhs
        }) {
            if DeterministicRecordID.isContribution(markerRecordName, for: key) {
                return key
            }
            if markerRecordName.hasPrefix(GoalService.drawdownPrefix(for: key)) {
                return key
            }
        }
        // WHY single owner: structural parse lives in GoalService so sheet plus grouping never drift.
        return GoalService.goalRecordName(fromMarkerRecordName: markerRecordName)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystemConstants.Padding.standard) {
                    headerView
                    if !shouldHideMovement {
                        moneyMovementSection
                    }
                    if !group.goalChildren.isEmpty {
                        goalImpactSection
                    }
                    if detailWhat != nil || detailWhere != nil || questWeekDetailText != nil {
                        detailsSection
                    }
                    balancesSection
                }
                .padding(DesignSystemConstants.Padding.standard)
            }
            .background(Color(DesignSystemConstants.Colors.cardSurface))
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("ledgerDetail.close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("ledgerDetail.sheet-\(group.groupID)")
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            if !group.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(group.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("ledgerDetail.type")
            }
            // WHY dash: net-zero transfers move between buckets with no gain, so an em dash reads neutral.
            if isNetZeroTransfer {
                Text("—")
                    .font(.headline.bold())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("no net change")
                    .accessibilityIdentifier("ledgerDetail.amount")
            } else {
                Text(CurrencyFormatter.signed(pennies: group.totalPennies))
                    .font(.headline.bold())
                    .foregroundStyle(group.totalPennies > 0 ? Color(DesignSystemConstants.Colors.primaryGreen) : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("ledgerDetail.amount")
            }
            Text("Posted \(LedgerRowStyle.shortDateText(for: group.date))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ledgerDetail.postedDate")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var moneyMovementSection: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            Text("MONEY MOVEMENT")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ledgerDetail.moneyMovementTitle")
            if group.splits.isEmpty {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // WHY single owner: transfer legs expand in splitRow so combined totals never render.
                ForEach(sortedSplits) { split in
                    splitRow(for: split)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("ledgerDetail.splits")
    }

    @ViewBuilder
    private func splitRow(for split: TransactionSplit) -> some View {
        if split.sourceEnum == .transfer,
           let fromKind = split.fromBucketEnum,
           let toKind = split.bucketKindEnum,
           fromKind != toKind
        {
            // WHY two legs: transfers relocate with no gain, so From plus To magnitudes read neutral without sign.
            let magnitudeText = CurrencyFormatter.magnitude(pennies: split.displayAmount(for: selectedBucketFilter))
            VStack(spacing: DesignSystemConstants.Padding.small) {
                HStack(spacing: DesignSystemConstants.Padding.small) {
                    Text("From \(fromKind.shortName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(magnitudeText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("From \(fromKind.shortName), \(magnitudeText)")
                HStack(spacing: DesignSystemConstants.Padding.small) {
                    Text("To \(toKind.shortName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(magnitudeText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("To \(toKind.shortName), \(magnitudeText)")
            }
        } else {
            // WHY neutral move: transfers relocate money with no gain, so magnitude plus secondary reads without sign.
            let isNeutralTransfer = split.sourceEnum == .transfer || isNetZeroTransfer
            let amount = split.displayAmount(for: selectedBucketFilter)
            let name = split.shortName.isEmpty ? group.title : split.shortName
            let amountText = isNeutralTransfer ? CurrencyFormatter.magnitude(pennies: amount) : CurrencyFormatter.signed(pennies: amount)
            let tint: Color = isNeutralTransfer ? .secondary : (amount > 0 ? Color(DesignSystemConstants.Colors.primaryGreen) : .primary)
            HStack(spacing: DesignSystemConstants.Padding.small) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(amountText)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(name), \(amountText)")
        }
    }

    private var goalImpactSection: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            Text("GOAL IMPACT")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ledgerDetail.goalImpactTitle")
            ForEach(group.goalChildren) { child in
                goalRow(for: child)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("ledgerDetail.goals")
    }

    @ViewBuilder
    private func goalRow(for child: TransactionSplit) -> some View {
        // WHY single resolve: one lookup per row keeps prefix matches deterministic plus avoids repeated scans.
        if let key = goalRecordName(for: child.recordName),
           let rawName = goalNames[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawName.isEmpty
        {
            if archivedGoalIDs.contains(key) {
                HStack(spacing: DesignSystemConstants.Padding.small) {
                    Image(systemName: "target")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(rawName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Archived")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color(DesignSystemConstants.Colors.tertiaryFill))
                        )
                        .accessibilityLabel("Archived")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(rawName), Archived, \(CurrencyFormatter.magnitude(pennies: child.amount))")
                .accessibilityIdentifier("ledgerDetail.goalArchived-\(child.recordName)")
            } else {
                let magnitude = CurrencyFormatter.magnitude(pennies: child.amount)
                Button {
                    onGoalTap?(key)
                } label: {
                    HStack(spacing: DesignSystemConstants.Padding.small) {
                        Image(systemName: "target")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(magnitude) · \(rawName)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(rawName), \(magnitude)")
                .accessibilityHint("Opens wishlist goal")
                .accessibilityIdentifier("ledgerDetail.goalTap-\(child.recordName)")
            }
        } else {
            HStack(spacing: DesignSystemConstants.Padding.small) {
                Image(systemName: "target")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Goal removed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Goal removed, \(CurrencyFormatter.magnitude(pennies: child.amount))")
            .accessibilityIdentifier("ledgerDetail.goalRemoved-\(child.recordName)")
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            Text("DETAILS")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ledgerDetail.detailsTitle")
            if let what = detailWhat {
                Text("What")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(what)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("ledgerDetail.what")
            }
            if let whereText = detailWhere {
                Text("Where")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(whereText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("ledgerDetail.where")
            }
            if let weekDetail = questWeekDetailText {
                Text("Week")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(weekDetail)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("ledgerDetail.week")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var balancesSection: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            Text("BALANCES AFTER POSTING")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ledgerDetail.balancesTitle")
            balanceRow(
                label: "Total",
                amount: group.runningTotalPennies,
                identifier: "ledgerDetail.balance",
                isTotal: true
            )
            balanceRow(
                label: "Spend",
                amount: group.runningByBucket[.spend] ?? 0,
                identifier: "ledgerDetail.balance-spend"
            )
            balanceRow(
                label: "Short Save",
                amount: group.runningByBucket[.shortTermSave] ?? 0,
                identifier: "ledgerDetail.balance-shortSave"
            )
            balanceRow(
                label: "Long Save",
                amount: group.runningByBucket[.longTermSave] ?? 0,
                identifier: "ledgerDetail.balance-longSave"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("ledgerDetail.balances")
    }

    private func balanceRow(label: String, amount: Int64, identifier: String, isTotal: Bool = false) -> some View {
        HStack(spacing: DesignSystemConstants.Padding.small) {
            Text(label)
                .font(isTotal ? .subheadline.bold() : .caption)
                .foregroundStyle(isTotal ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(CurrencyFormatter.string(pennies: amount))
                .font(isTotal ? .subheadline.bold().monospacedDigit() : .caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(isTotal ? .primary : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) balance after posting \(CurrencyFormatter.string(pennies: amount))")
        .accessibilityIdentifier(identifier)
    }
}

extension TransactionSplit {
    /// WHY from-to: transfers credit the destination while debiting the source, so one label reads both sides.
    var shortName: String {
        if let fromKind = fromBucketEnum, let toKind = bucketKindEnum ?? toBucketEnum {
            if fromKind != toKind {
                return "\(fromKind.shortName) to \(toKind.shortName)"
            }
            return toKind.shortName
        }
        if let kind = bucketKindEnum ?? toBucketEnum {
            return kind.shortName
        }
        if let fromKind = fromBucketEnum {
            return fromKind.shortName
        }
        return ""
    }
}
