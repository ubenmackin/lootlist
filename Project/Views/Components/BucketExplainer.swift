//
//  BucketExplainer.swift
//  LootList
//
//  Created by Ben Mackin on 9/5/26.
//

import SwiftUI

/// Shared 3-bucket explainer — static copy-only variant for compact help surfaces.
/// WHY distinct from BucketEducationBannerView: no queries, no dismissal, no sheets;
/// the banner is the interactive discovery-surface variant with live split %.
struct BucketExplainer: View {
    static let title = "How your allowance splits"
    static let subtitle = "Future payouts only — your %s decide where money goes. Goals fill FIFO in that bucket."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.title)
                .font(.headline)
            Text(Self.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                BucketColumnView(emoji: "🛒", title: "Spend", tint: Color(DesignSystemConstants.Colors.primaryGreen))
                BucketColumnView(emoji: "🐿️", title: "Short", tint: Color(DesignSystemConstants.Colors.accentBlue))
                BucketColumnView(emoji: "🏦", title: "Long", tint: Color(DesignSystemConstants.Colors.pendingAmber))
            }
        }
    }
}
