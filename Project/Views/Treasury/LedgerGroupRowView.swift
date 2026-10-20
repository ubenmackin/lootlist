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
        group.totalPennies >= 0
            ? Color(DesignSystemConstants.Colors.gold)
            : Color(DesignSystemConstants.Colors.dangerRed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            headerRow
            if shouldShowDetails {
                splitsSection
                if !group.goalChildren.isEmpty {
                    goalSection
                }
            } else {
                collapsedPillsRow
            }
        }
        .padding(DesignSystemConstants.Padding.medium)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.title), \(totalText), \(LedgerRowStyle.dateText(for: group.date))")
        .accessibilityIdentifier("ledger.group-\(group.groupID)")
    }

    private var headerRow: some View {
        // WHY tappable header: progressive disclosure routes every tap through onToggle so default-expanded groups collapse too.
        Button {
            onToggle()
        } label: {
            HStack(alignment: .top, spacing: DesignSystemConstants.Padding.medium) {
                let iconInfo = LedgerRowStyle.sourceIcon(
                    for: group.source,
                    fallbackTint: Color(DesignSystemConstants.Colors.accentBlue)
                )
                Image(systemName: iconInfo.name)
                    .font(.body)
                    .foregroundStyle(iconInfo.color)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(iconInfo.color.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(LedgerRowStyle.dateText(for: group.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Balance \(runningText)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: DesignSystemConstants.Padding.small)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(totalText)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(totalColor)
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

    private var collapsedPillsRow: some View {
        HStack(spacing: 6) {
            if transferPairs.isEmpty {
                ForEach(distinctBuckets, id: \.self) { kind in
                    bucketPill(kind)
                }
            } else {
                ForEach(Array(transferPairs.enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 4) {
                        bucketPill(pair.from)
                        // WHY both sides: transfers debit the source while crediting the destination, so collapsed pills show Spend → Short.
                        Text("→")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                        bucketPill(pair.to)
                    }
                }
                ForEach(standaloneBuckets, id: \.self) { kind in
                    bucketPill(kind)
                }
            }
        }
    }

    private var splitsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(group.splits) { split in
                // WHY per-filter legs: source-side transfers read as debits so filtered copy matches bucket math.
                let displayPennies = split.displayAmount(for: selectedBucketFilter)
                HStack(spacing: 6) {
                    splitBucketPills(for: split)
                    if let location = split.location, !location.isEmpty {
                        Text(location)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(CurrencyFormatter.signed(pennies: displayPennies))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(
                            displayPennies >= 0
                                ? Color(DesignSystemConstants.Colors.gold)
                                : Color(DesignSystemConstants.Colors.dangerRed)
                        )
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(split.entryDescription), \(bucketDescription(for: split)), \(CurrencyFormatter.signed(pennies: displayPennies))")
            }
        }
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
                    Spacer(minLength: 8)
                    // WHY zero counted: goal attribution reuses counted funds, so trail shows $0.00 non-counted while copy carries the attribution magnitude.
                    Text(CurrencyFormatter.string(pennies: 0))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, DesignSystemConstants.Padding.standard)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(goalCopy(for: child)), \(CurrencyFormatter.string(pennies: 0)) non-counted")
            }
        }
    }

    private var distinctBuckets: [BucketKind] {
        // WHY both sides: transfers debit fromBucket while crediting the destination, so pills claim both buckets.
        var seen: [BucketKind] = []
        for split in group.splits {
            if let fromKind = split.fromBucketEnum,
               !seen.contains(fromKind)
            {
                seen.append(fromKind)
            }
            guard let kind = split.bucketKindEnum, !seen.contains(kind) else { continue }
            seen.append(kind)
        }
        return seen
    }

    private var transferPairs: [(from: BucketKind, to: BucketKind)] {
        var seen: [(from: BucketKind, to: BucketKind)] = []
        for split in group.splits {
            guard let fromKind = split.fromBucketEnum,
                  let toKind = split.bucketKindEnum,
                  fromKind != toKind
            else { continue }
            if !seen.contains(where: { $0.from == fromKind && $0.to == toKind }) {
                seen.append((from: fromKind, to: toKind))
            }
        }
        return seen
    }

    private var standaloneBuckets: [BucketKind] {
        let paired = Set(transferPairs.flatMap { [$0.from, $0.to] })
        return distinctBuckets.filter { !paired.contains($0) }
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

    private func splitBucketPills(for split: TransactionSplit) -> some View {
        HStack(spacing: 4) {
            if let fromKind = split.fromBucketEnum,
               let toKind = split.bucketKindEnum
            {
                if fromKind != toKind {
                    bucketPill(fromKind)
                    // WHY both sides: transfers debit the source while crediting the destination, so splits show Spend → Short.
                    Text("→")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    bucketPill(toKind)
                } else {
                    bucketPill(toKind)
                }
            } else if let kind = split.bucketKindEnum {
                bucketPill(kind)
            } else if let fromKind = split.fromBucketEnum {
                bucketPill(fromKind)
            }
        }
    }

    private func bucketPill(_ kind: BucketKind) -> some View {
        HStack(spacing: 3) {
            Image(systemName: kind.iconSystemName)
                .font(.system(size: 9))
            Text(kind.shortName)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.12)))
        .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
    }

    private func goalCopy(for child: TransactionSplit) -> String {
        if child.amount >= 0 {
            return "Applied \(CurrencyFormatter.magnitude(pennies: child.amount)) to goal"
        }
        return "Borrowed \(CurrencyFormatter.magnitude(pennies: child.amount)) from goal"
    }
}
