//
//  BucketSplitEntryRow.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftUI

/// Card row linking to the Bucket Split editor view.
struct BucketSplitEntryRow: View {
    /// Accessibility identifier for the tappable row. Pass
    /// `ledger.bucketSplitRow` or `heroDetail.bucketSplitRow` to preserve
    /// existing UI-test hooks.
    let accessibilityIdentifier: String

    /// Invoked when the row is tapped, after light haptic feedback.
    let onTap: () -> Void

    var body: some View {
        Button {
            HapticsService.lightImpact()
            onTap()
        } label: {
            HStack(spacing: DesignSystemConstants.Padding.medium) {
                Image(systemName: "chart.pie.fill")
                    .font(.body)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Bucket Split")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Applies to future payouts and deposits only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(DesignSystemConstants.Padding.medium)
            .background(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
