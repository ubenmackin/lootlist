//
//  BucketColumnView.swift
//  LootList
//
//  Created by Ben Mackin on 9/6/26.
//

import SwiftUI

/// Shared 3-bucket column cell used by the interactive banner and the static explainer.
/// WHY shared: the emoji/title/tint cell was duplicated across both surfaces; one view keeps them from drifting.
struct BucketColumnView: View {
    let emoji: String
    let title: String
    let percent: Int?
    let tint: Color
    var accessibilityID: String?

    init(emoji: String, title: String, percent: Int? = nil, tint: Color, accessibilityID: String? = nil) {
        self.emoji = emoji
        self.title = title
        self.percent = percent
        self.tint = tint
        self.accessibilityID = accessibilityID
    }

    var body: some View {
        if let accessibilityID {
            columnContent
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(accessibilityID)
        } else {
            columnContent
        }
    }

    private var columnContent: some View {
        VStack(spacing: 6) {
            Text(emoji)
                .font(.title3)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let percent {
                Text("\(percent)%")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(tint.opacity(0.15))
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
        )
    }
}
