//
//  LedgerGroupRowView.swift
//  LootList
//
//  Created by Ben Mackin on 10/20/26.
//

import SwiftUI

/// Shared grouped ledger card used by child and parent ledgers.
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.title), \(totalText), \(LedgerRowStyle.shortDateText(for: group.date))")
        .accessibilityIdentifier("ledger.group-\(group.groupID)")
    }

    private var headerRow: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: DesignSystemConstants.Padding.small) {
                Text("\(Text(group.title).foregroundStyle(.primary))\(Text(" • \(LedgerRowStyle.shortDateText(for: group.date))").foregroundStyle(.secondary))")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(totalText)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(group.totalPennies >= 0 ? .primary : Color(DesignSystemConstants.Colors.dangerRed))
                    .frame(minWidth: 78, alignment: .trailing)
                    .lineLimit(1)
                Text(CurrencyFormatter.string(pennies: group.runningPennies(for: selectedBucketFilter)))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color(DesignSystemConstants.Colors.gold))
                    .frame(minWidth: 78, alignment: .trailing)
                    .lineLimit(1)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
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
        // WHY single sort: ForEach plus anchor share one sorted array so indices cannot drift.
        let sorted = sortedSplits
        let anchor = shortAnchorIndex(in: sorted)
        return VStack(alignment: .leading, spacing: 6) {
            if let weekDetail = questWeekDetailText {
                detailLine(text: weekDetail)
            }
            if let detail = spendDetailText {
                detailLine(text: detail)
            }
            ForEach(Array(sorted.enumerated()), id: \.element.id) { index, split in
                splitRow(for: split)
                // WHY Short anchor: goal copy reads indented under Short Save even with Long legs present.
                if index == anchor {
                    goalSection
                }
            }
            // WHY trailing fallback: groups without Short legs still surface goals instead of dropping them.
            if !group.goalChildren.isEmpty, anchor == nil {
                goalSection
            }
        }
    }

    private func detailLine(text: String) -> some View {
        // WHY shared geometry: empty Amount plus Balance spacers keep Type left edge identical to header.
        HStack(spacing: DesignSystemConstants.Padding.small) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(minWidth: 78, minHeight: 1)
            Color.clear.frame(minWidth: 78, minHeight: 1)
            Color.clear.frame(width: 20, height: 20)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    private func shortAnchorIndex(in sorted: [TransactionSplit]) -> Int? {
        guard !group.goalChildren.isEmpty else { return nil }
        let shortIndices = sorted.indices.filter { sorted[$0].bucketKindEnum == .shortTermSave }
        return shortIndices.last
    }

    private func splitRow(for split: TransactionSplit) -> some View {
        // WHY shared geometry: identical 78 plus 78 plus 20 spacers pixel-match header Amount right edge.
        // WHY per-filter legs: displayAmount flips transfer source-debit sign under filter so filtered math stays correct.
        let displayPennies = split.displayAmount(for: selectedBucketFilter)
        let amountText = CurrencyFormatter.signed(pennies: displayPennies)
        let typeName = split.shortName.isEmpty ? group.title : split.shortName
        return HStack(spacing: DesignSystemConstants.Padding.small) {
            Text(typeName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(amountText)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(displayPennies >= 0 ? .primary : Color(DesignSystemConstants.Colors.dangerRed))
                .frame(minWidth: 78, alignment: .trailing)
                .lineLimit(1)
            Color.clear.frame(minWidth: 78, minHeight: 1)
            Color.clear.frame(width: 20, height: 20)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(typeName), \(amountText)")
    }

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(group.goalChildren) { child in
                HStack(spacing: DesignSystemConstants.Padding.small) {
                    Image(systemName: "target")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(goalCopy(for: child))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // WHY shared geometry: empty Amount plus Balance spacers keep goal right edge identical to header.
                    Color.clear.frame(minWidth: 78, minHeight: 1)
                    Color.clear.frame(minWidth: 78, minHeight: 1)
                    Color.clear.frame(width: 20, height: 20)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, DesignSystemConstants.Padding.standard)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(goalCopy(for: child))
            }
        }
    }

    private func goalCopy(for child: TransactionSplit) -> String {
        // WHY amount-only: magnitude rides inline so no parenthetical now status ever renders; totals live on goal screens.
        let magnitude = CurrencyFormatter.magnitude(pennies: child.amount)
        let rawName = child.entryDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if child.amount >= 0 {
            if rawName.isEmpty {
                return "Applied \(magnitude) to goal"
            }
            return "Applied \(magnitude) to goal \(rawName)"
        }
        if rawName.isEmpty {
            return "Borrowed \(magnitude) from goal"
        }
        return "Borrowed \(magnitude) from goal \(rawName)"
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
