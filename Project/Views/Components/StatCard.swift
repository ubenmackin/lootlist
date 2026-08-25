//
//  StatCard.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftUI

/// A concise stat display — icon, value, and label — used on dashboard
/// hero cards and summary strips. Tint defaults to primary green.
struct StatCard: View {
    let title: String

    let value: String

    var icon: String?

    var tint: Color = .init(DesignSystemConstants.Colors.primaryGreen)

    var body: some View {
        VStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
            }

            Text(value)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.primary)

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystemConstants.Padding.medium)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small,
                             style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
    }
}
