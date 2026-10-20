//
//  LedgerBalanceHeaderView.swift
//  LootList
//
//  Created by Ben Mackin on 10/20/26.
//

import SwiftUI

struct LedgerBalanceHeaderView: View {
    let totalBalance: Int64?
    let bucketBalances: [BucketKind: Int64]
    let selectedBucketFilter: BucketKind?
    let pendingPayoutAmount: Int64?
    let onSelectTotal: () -> Void
    let onSelectBucket: (BucketKind) -> Void

    init(
        totalBalance: Int64?,
        bucketBalances: [BucketKind: Int64],
        selectedBucketFilter: BucketKind?,
        pendingPayoutAmount: Int64? = nil,
        onSelectTotal: @escaping () -> Void,
        onSelectBucket: @escaping (BucketKind) -> Void
    ) {
        self.totalBalance = totalBalance
        self.bucketBalances = bucketBalances
        self.selectedBucketFilter = selectedBucketFilter
        self.pendingPayoutAmount = pendingPayoutAmount
        self.onSelectTotal = onSelectTotal
        self.onSelectBucket = onSelectBucket
    }

    var body: some View {
        VStack(spacing: 12) {
            totalBalanceCard
            bucketFilterRow
        }
    }

    private var totalBalanceCard: some View {
        Button {
            HapticsService.lightImpact()
            onSelectTotal()
        } label: {
            VStack(spacing: 16) {
                Text(totalText)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(totalColor)
                    .contentTransition(.numericText())

                Text("Money (Wallet Balance)")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                if let pendingPayoutAmount, pendingPayoutAmount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                        Text("\(CurrencyFormatter.string(pendingPayoutAmount)) Pending Weekly Payout")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.12))
                    )
                    .overlay(
                        Capsule().strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.40), lineWidth: 1)
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            )
            .padding(.horizontal)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current balance \(totalAccessibilityText)")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ledger.totalCard")
        .accessibilityLabel("Total balance, show all buckets")
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .strokeBorder(
                    selectedBucketFilter == nil ? Color(DesignSystemConstants.Colors.accentBlue) : Color.clear,
                    lineWidth: selectedBucketFilter == nil ? 2 : 0
                )
        }
    }

    private var totalText: String {
        // WHY signed total: overdraft drives Total negative so the header shows sign plus red like tiles and rows.
        guard let totalBalance else { return "—" }
        return CurrencyFormatter.string(pennies: totalBalance)
    }

    private var totalColor: Color {
        guard let totalBalance else { return .secondary }
        return totalBalance < 0 ? Color(DesignSystemConstants.Colors.dangerRed) : .primary
    }

    private var totalAccessibilityText: String {
        guard let totalBalance else { return "loading" }
        return CurrencyFormatter.string(pennies: totalBalance)
    }

    private var bucketFilterRow: some View {
        HStack(spacing: 12) {
            bucketFilterButton(kind: .spend)
            bucketFilterButton(kind: .shortTermSave)
            bucketFilterButton(kind: .longTermSave)
        }
        .padding(.horizontal)
    }

    private func bucketFilterButton(kind: BucketKind) -> some View {
        // WHY kind-driven: tile copy derives from BucketKind so bucket renames never drift across surfaces.
        // WHY local tile: BucketTileView is a frosted white-on-dark hero tile; these tiles sit on
        // the default background so they use token-aware surfaces with red for negative balances.
        let title = kind.shortName.uppercased()
        let isSelected = selectedBucketFilter == kind
        let amount = bucketBalances[kind] ?? 0
        return Button {
            HapticsService.rigid()
            onSelectBucket(kind)
        } label: {
            LedgerBucketFilterTile(
                title: title,
                amount: amount,
                accessibilityID: LedgerBucketFilter.tileAccessibilityID(for: kind)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color(DesignSystemConstants.Colors.accentBlue) : Color.clear,
                        lineWidth: isSelected ? 2 : 0
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.displayName) bucket filter, \(CurrencyFormatter.string(pennies: amount))")
        .accessibilityHint(isSelected ? "Selected, tap to show all" : "Tap to filter to \(kind.displayName)")
    }
}

/// Token-aware bucket-filter tile for ledger headers on the default background.
private struct LedgerBucketFilterTile: View {
    let title: String
    let amount: Int64

    var accessibilityID: String?

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(CurrencyFormatter.string(pennies: amount))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(amount < 0 ? Color(DesignSystemConstants.Colors.dangerRed) : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .hoverEffect(.highlight)
        .accessibilityIdentifierIfSet(accessibilityID)
    }
}

/// Shared bucket-filter identity so tiles never drift across ledger surfaces.
enum LedgerBucketFilter {
    static func tileAccessibilityID(for kind: BucketKind) -> String {
        switch kind {
        case .spend: "ledger.bucketTile-spend"
        case .shortTermSave: "ledger.bucketTile-shortSave"
        case .longTermSave: "ledger.bucketTile-longSave"
        }
    }

    /// WHY toggle: tapping the active bucket clears back to All.
    static func toggled(_ current: BucketKind?, with kind: BucketKind) -> BucketKind? {
        current == kind ? nil : kind
    }
}

/// Shared empty-state copy so filtered versus unfiltered titles never drift.
enum LedgerEmptyState {
    static func title(for filter: BucketKind?, defaultTitle: String) -> String {
        if let filter {
            return "No \(filter.shortName) activity"
        }
        return defaultTitle
    }
}
