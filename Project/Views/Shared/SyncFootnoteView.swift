//
//  SyncFootnoteView.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import SwiftUI

/// Prod-safe sync footnote shared by ledger and quest surfaces.
/// WHY single source: Treasury and Quest Log built identical sync states; one view keeps copy and colors from drifting.
struct SyncFootnoteView: View {
    let pendingCount: Int
    let isSyncing: Bool
    let lastSyncedAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            if isSyncing {
                ProgressView()
                    .tint(Color(DesignSystemConstants.Colors.accentBlue))
                    .accessibilityHidden(true)
                Text("Syncing…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
            } else if pendingCount > 0 {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                    .accessibilityHidden(true)
                Text("\(pendingCount) pending upload\(pendingCount == 1 ? "" : "s")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                if let last = lastSyncedAt {
                    Text("· Last synced \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let last = lastSyncedAt {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                    .accessibilityHidden(true)
                Text("Last synced \(last.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not yet synced")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .accessibilityElement(children: .combine)
    }
}
