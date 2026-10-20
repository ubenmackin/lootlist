//
//  LedgerGroupRowView.swift
//  LootList
//
//  Created by Ben Mackin on 10/20/26.
//

import SwiftUI

/// Shared three-line grouped ledger card used by child and parent ledgers.
struct LedgerGroupRowView: View {
    let group: TransactionGroup
    let isExpanded: Bool
    let onToggle: () -> Void
    /// Nil shows Total running; non-nil shows that bucket's running.
    let selectedBucketFilter: BucketKind?

    init(group: TransactionGroup, isExpanded: Bool, onToggle: @escaping () -> Void, selectedBucketFilter: BucketKind? = nil) {
        self.group = group
        self.isExpanded = isExpanded
        self.onToggle = onToggle
        self.selectedBucketFilter = selectedBucketFilter
    }

    private var shouldShowDetails: Bool {
        isExpanded
    }

    private var totalText: String {
        CurrencyFormatter.signed(pennies: group.totalPennies)
    }

    private var runningText: String {
        // WHY per-filter running: All shows Total while each bucket filter shows its own bucket running.
        CurrencyFormatter.string(pennies: group.runningPennies(for: selectedBucketFilter))
    }

    private var totalColor: Color {
        // WHY adaptive amount: receipt totals read as primary ink while overdrafts flag red.
        group.totalPennies >= 0
            ? .primary
            : Color(DesignSystemConstants.Colors.dangerRed)
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
        // WHY source-first: transfers debit the source, so Spend→Short reads under Spend with real Spend legs.
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

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            headerRow
            if shouldShowDetails {
                splitsSection
            }
        }
        .padding(DesignSystemConstants.Padding.medium)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.title), \(totalText), \(LedgerRowStyle.shortDateText(for: group.date))")
        .accessibilityIdentifier("ledger.group-\(group.groupID)")
    }

    private var headerRow: some View {
        // WHY tappable header: progressive disclosure routes every tap through onToggle so default-expanded groups collapse too.
        Button {
            onToggle()
        } label: {
            HStack(alignment: .top, spacing: DesignSystemConstants.Padding.medium) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(LedgerRowStyle.shortDateText(for: group.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: DesignSystemConstants.Padding.small)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(totalText)
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(totalColor)
                        .lineLimit(1)
                    Text("Balance \(runningText)")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color(DesignSystemConstants.Colors.gold))
                        .lineLimit(1)
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse details for \(group.title)" : "Expand details for \(group.title)")
        .accessibilityIdentifier("ledger.expand-\(group.groupID)")
    }

    private var representativeSplit: TransactionSplit? {
        // WHY single owner: receipt anchor lives on the group so view plus builder never drift.
        group.representativeSplit
    }

    private var spendDetailText: String? {
        // WHY spend-only: What-Where belongs to manual spend receipts; other types keep bucket legs alone.
        guard group.sourceEnum == .manual, let representative = representativeSplit else { return nil }
        let what = representative.entryDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !what.isEmpty else { return nil }
        let whereText = (representative.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if whereText.isEmpty {
            return what
        }
        return "\(what) at \(whereText)"
    }

    private var questWeekDetailText: String? {
        // WHY builder-owned week: representative entry owns the payout week label so filtered receipts read the same.
        TransactionGroupBuilder.questWeekDetailText(for: group)
    }

    private var splitsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let weekDetail = questWeekDetailText {
                Text(weekDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(weekDetail)
            }
            if let detail = spendDetailText {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(detail)
            }
            ForEach(Array(sortedSplits.enumerated()), id: \.element.id) { index, split in
                splitRow(for: split)
                // WHY Short anchor: goal copy reads indented under Short Save even with Long legs present.
                if index == shortAnchorIndex {
                    goalSection
                }
            }
            // WHY trailing fallback: groups without Short legs still surface goals instead of dropping them.
            if !group.goalChildren.isEmpty, shortAnchorIndex == nil {
                goalSection
            }
        }
    }

    private var shortAnchorIndex: Int? {
        guard !group.goalChildren.isEmpty else { return nil }
        // WHY single sort: capture once so the index filter cannot re-sort per element.
        let sorted = sortedSplits
        let shortIndices = sorted.indices.filter { sorted[$0].bucketKindEnum == .shortTermSave }
        return shortIndices.last
    }

    private func splitRow(for split: TransactionSplit) -> some View {
        // WHY per-filter legs: source-side transfers read as debits so filtered copy matches bucket math.
        let displayPennies = split.displayAmount(for: selectedBucketFilter)
        let bucketText = bucketDescription(for: split)
        // WHY title fallback: splits without bucket attribution still need a leading label.
        let displayBucketText = bucketText.isEmpty ? group.title : bucketText
        return HStack(spacing: 6) {
            Text(displayBucketText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(CurrencyFormatter.signed(pennies: displayPennies))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(
                    displayPennies >= 0
                        ? .primary
                        : Color(DesignSystemConstants.Colors.dangerRed)
                )
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayBucketText), \(CurrencyFormatter.signed(pennies: displayPennies))")
    }

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(group.goalChildren) { child in
                HStack(spacing: 6) {
                    Image(systemName: "target")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(goalCopy(for: child))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, DesignSystemConstants.Padding.standard)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(goalCopy(for: child))
            }
        }
    }

    private func bucketDescription(for split: TransactionSplit) -> String {
        if let fromKind = split.fromBucketEnum,
           let toKind = split.bucketKindEnum
        {
            if fromKind != toKind {
                return "\(fromKind.shortName) to \(toKind.shortName)"
            }
            return toKind.shortName
        }
        if let kind = split.bucketKindEnum {
            return kind.shortName
        }
        if let fromKind = split.fromBucketEnum {
            return fromKind.shortName
        }
        return ""
    }

    private func goalCopy(for child: TransactionSplit) -> String {
        // WHY amount-only: magnitude rides inline so no parenthetical now status ever renders; totals live on goal screens.
        let magnitude = CurrencyFormatter.magnitude(pennies: child.amount)
        if child.amount >= 0 {
            return "Applied \(magnitude) to goal"
        }
        return "Borrowed \(magnitude) from goal"
    }
}
