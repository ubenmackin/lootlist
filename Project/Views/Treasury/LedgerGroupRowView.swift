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
    /// Nil shows Total running; non-nil shows that bucket's running.
    let selectedBucketFilter: BucketKind?
    let onSelect: () -> Void

    init(group: TransactionGroup, selectedBucketFilter: BucketKind? = nil, onSelect: @escaping () -> Void) {
        self.group = group
        self.selectedBucketFilter = selectedBucketFilter
        self.onSelect = onSelect
    }

    private var isNetZeroTransfer: Bool {
        group.totalPennies == 0 && group.sourceEnum == .transfer
    }

    private var icon: (systemName: String, color: Color) {
        LedgerRowStyle.rowIcon(for: group.sourceEnum)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: DesignSystemConstants.Padding.medium) {
                Image(systemName: icon.systemName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(icon.color)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(icon.color.opacity(0.12)))
                    .accessibilityHidden(true)
                VStack(spacing: 2) {
                    HStack {
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // WHY dash: net-zero transfers move between buckets with no gain, so an em dash reads neutral.
                        if isNetZeroTransfer {
                            Text("—")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityLabel("no net change")
                        } else {
                            Text(CurrencyFormatter.signed(pennies: group.totalPennies))
                                .font(.headline.weight(.bold).monospacedDigit())
                                .foregroundStyle(group.totalPennies > 0 ? Color(DesignSystemConstants.Colors.primaryGreen) : .primary)
                                .lineLimit(1)
                        }
                    }
                    HStack {
                        Text(LedgerRowStyle.shortDateText(for: group.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(CurrencyFormatter.string(pennies: group.runningPennies(for: selectedBucketFilter)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(DesignSystemConstants.Padding.medium)
            .background(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("ledger.group-\(group.groupID)")
    }

    private var accessibilitySummary: String {
        if isNetZeroTransfer {
            "\(group.title), no net change, \(LedgerRowStyle.shortDateText(for: group.date))"
        } else {
            "\(group.title), \(CurrencyFormatter.signed(pennies: group.totalPennies)), \(LedgerRowStyle.shortDateText(for: group.date))"
        }
    }
}
