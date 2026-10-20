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

    @Environment(\.dismiss) private var dismiss

    init(group: TransactionGroup, selectedBucketFilter: BucketKind? = nil) {
        self.group = group
        self.selectedBucketFilter = selectedBucketFilter
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

    private var representativeSplit: TransactionSplit? {
        group.representativeSplit
    }

    private var spendDetailText: String? {
        // WHY spend-only: manual spends alone carry what-where copy, other sources would misread.
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
        // WHY builder-owned: week copy lives in the builder so sheet plus rows never drift.
        TransactionGroupBuilder.questWeekDetailText(for: group)
    }

    private func goalCopy(for child: TransactionSplit) -> String {
        // WHY amount-only: sign alone decides Applied versus Borrowed so empty names stay truthful.
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystemConstants.Padding.standard) {
                    headerView
                    splitsSection
                    whatWhereSection
                    goalsSection
                    weekSection
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
            Text(CurrencyFormatter.signed(pennies: group.totalPennies))
                .font(.headline.bold())
                .foregroundStyle(group.totalPennies >= 0 ? Color(DesignSystemConstants.Colors.primaryGreen) : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ledgerDetail.amount")
            Text("Posted \(LedgerRowStyle.shortDateText(for: group.date))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ledgerDetail.postedDate")
            Text("Balance after posting \(CurrencyFormatter.string(pennies: group.runningPennies(for: selectedBucketFilter)))")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ledgerDetail.balance")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var splitsSection: some View {
        if group.splits.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
                ForEach(sortedSplits) { split in
                    splitRow(for: split)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("ledgerDetail.splits")
        }
    }

    private func splitRow(for split: TransactionSplit) -> some View {
        let amount = split.displayAmount(for: selectedBucketFilter)
        let name = split.shortName.isEmpty ? group.title : split.shortName
        let amountText = CurrencyFormatter.signed(pennies: amount)
        let tint: Color = amount >= 0 ? Color(DesignSystemConstants.Colors.primaryGreen) : .primary
        return HStack(spacing: DesignSystemConstants.Padding.small) {
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

    @ViewBuilder
    private var whatWhereSection: some View {
        if let detail = spendDetailText {
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ledgerDetail.whatWhere")
        }
    }

    @ViewBuilder
    private var goalsSection: some View {
        if group.goalChildren.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
                ForEach(group.goalChildren) { child in
                    HStack(spacing: DesignSystemConstants.Padding.small) {
                        Image(systemName: "target")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(goalCopy(for: child))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(goalCopy(for: child))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("ledgerDetail.goals")
        }
    }

    @ViewBuilder
    private var weekSection: some View {
        if let weekDetail = questWeekDetailText {
            Text(weekDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ledgerDetail.week")
        }
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
