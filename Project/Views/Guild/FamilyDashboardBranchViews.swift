//
//  FamilyDashboardBranchViews.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import Charts
import SwiftUI

struct FamilyDashboardContentView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
    }
}

struct FamilyDashboardEmptyView: View {
    var body: some View {
        DashboardLoadingPlaceholder()
    }
}

struct FamilyDashboardSparklineCard: View {
    let points: [WeeklyEarningPoint]
    let total: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("EARNING TREND — 6 WEEKS") {
                Text(CurrencyFormatter.string(total))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
            }
            if points.allSatisfy({ $0.amount == 0 }) {
                Text("No earnings yet — complete quests to see the trend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 80, alignment: .center)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                            .fill(Color(DesignSystemConstants.Colors.cardSurface))
                    )
            } else {
                Chart(points) { point in
                    BarMark(
                        x: .value("Week", point.label),
                        y: .value("Earned", point.amount)
                    )
                    .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                    .cornerRadius(4)
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic) { _ in
                        AxisValueLabel()
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                .frame(height: 80)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                        .fill(Color(DesignSystemConstants.Colors.cardSurface))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
                )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("6 week earning trend")
        .accessibilityIdentifier("dashboard.earningSparkline")
    }
}

struct FamilyDashboardSchedulePill: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            )
    }
}

struct FamilyDashboardPendingRowHeader: View {
    let questName: String
    let heroName: String
    let scheduleLabel: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(questName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("Submitted by \(heroName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !scheduleLabel.isEmpty {
                FamilyDashboardSchedulePill(label: scheduleLabel)
            }
        }
    }
}

struct FamilyDashboardWeeklySummaryHeader: View {
    let title: String
    let subtitle: String
    let subtitleColor: Color
    let weekOf: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(subtitleColor)
            }
            Spacer()
            Text(weekOf, format: .dateTime.month().day())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// WHY split sidebar lifecycle into a typed modifier: the 13-deep chain stalls the type-checker.
struct DashboardSidebarLifecycle: ViewModifier {
    let cachedProfiles: [ProfileCache]
    let cachedQuests: [QuestCache]
    let cachedCompletions: [QuestCompletionCache]
    let cachedLedgers: [LedgerEntryCache]
    let cachedAllowancePeriods: [AllowancePeriodCache]
    let cachedAchievements: [AchievementCache]
    let cachedProfileAchievements: [ProfileAchievementCache]
    let childCardID: String?
    let onAppear: () async -> Void
    let onRefresh: () async -> Void
    let onProfilesChanged: () -> Void
    let onCacheChanged: () -> Void
    let onAutoSelect: () -> Void
    let onDisappear: () -> Void

    func body(content: Content) -> some View {
        applyRemaining(to: applyCore(to: content))
    }

    private func applyCore(to content: Content) -> some View {
        content
            .refreshable { await onRefresh() }
            .task { await onAppear() }
            .onChange(of: childCardID) { _, _ in onAutoSelect() }
            .onChange(of: cachedProfiles) { _, _ in onProfilesChanged() }
            .onChange(of: cachedQuests) { _, _ in onCacheChanged() }
    }

    private func applyRemaining(to view: some View) -> some View {
        view
            .onChange(of: cachedCompletions) { _, _ in onCacheChanged() }
            .onChange(of: cachedLedgers) { _, _ in onCacheChanged() }
            .onChange(of: cachedAllowancePeriods) { _, _ in onCacheChanged() }
            .onChange(of: cachedAchievements) { _, _ in onCacheChanged() }
            .onChange(of: cachedProfileAchievements) { _, _ in onCacheChanged() }
            .onDisappear { onDisappear() }
    }
}
