//
//  FamilyDashboardWeeklySummaryView.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import SwiftData
import SwiftUI

/// Weekly earnings summary extracted from FamilyDashboardView; subtitle math
/// lives on FamilyDashboardViewModel so the view stays declarative.
struct FamilyDashboardWeeklySummaryView: View {
    let summary: WeekendSummary?
    let lootDayTitle: String
    let viewerIsHero: Bool
    let familyPayoutPolicy: PayoutPolicy?
    let isProcessingPayout: Bool
    let onConfirmPayout: () async -> Void

    var body: some View {
        if let summary {
            let isPending = summary.pendingPayoutAmount > 0
            let allRealTime = summary.heroSummaries.allSatisfy {
                ($0.profile.payoutPolicyEnum ?? familyPayoutPolicy ?? .perQuest) == .realTime
            }
            let showsSettled = allRealTime && summary.totalEarned > 0
            let subtitle = FamilyDashboardViewModel.weeklySubtitle(
                lootDayTitle: lootDayTitle,
                isPending: isPending,
                showsSettled: showsSettled
            )
            let subtitleColor = showsSettled ? Color(DesignSystemConstants.Colors.primaryGreen) : Color.secondary
            let showsPayout = isPending && !viewerIsHero
            VStack(alignment: .leading, spacing: 12) {
                FamilyDashboardWeeklySummaryHeader(
                    title: "This Week's Earnings",
                    subtitle: subtitle,
                    subtitleColor: subtitleColor,
                    weekOf: summary.weekOf
                )
                DashboardTotalsRow(summary: summary, isPending: isPending)
                if showsPayout {
                    ProcessPayoutButtonView(
                        summary: summary,
                        isProcessingPayout: isProcessingPayout,
                        onConfirmPayout: onConfirmPayout
                    )
                    .padding(.top, 4)
                }
            }
            .padding(DesignSystemConstants.Padding.standard)
            .background(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.30), lineWidth: 1)
            )
        }
    }
}
