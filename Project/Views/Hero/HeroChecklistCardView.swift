//
//  HeroChecklistCardView.swift
//  LootList
//
//  Created by Ben Mackin on 9/5/26.
//

import SwiftData
import SwiftUI

struct HeroChecklistCardView: View {
    enum ChecklistItem: String, Identifiable, Sendable, CaseIterable {
        case notifications
        case buckets
        case firstQuest
        case firstGoal

        var id: String {
            rawValue
        }
    }

    let profileRow: ProfileCache
    let pendingNotification: Bool
    let splitIsDefault: Bool
    let hasCompletedFirstQuest: Bool
    let hasFirstGoal: Bool
    let onAction: (ChecklistItem) -> Void
    @Binding var hasDismissedHeroChecklist: Bool

    private var items: [(item: ChecklistItem, isDone: Bool)] {
        [
            (.notifications, !pendingNotification),
            (.buckets, !splitIsDefault),
            (.firstQuest, hasCompletedFirstQuest),
            (.firstGoal, hasFirstGoal)
        ]
    }

    private var incompleteItems: [(item: ChecklistItem, isDone: Bool)] {
        items.filter { !$0.isDone }
    }

    private var completedCount: Int {
        items.filter(\.isDone).count
    }

    private var totalCount: Int {
        items.count
    }

    var body: some View {
        // Fail-closed: parent already gates on row presence; this guard keeps previews safe when filtered to done.
        // WHY single source: dismissal owned by parent HeroHomeView via scoped binding to avoid dual wrappers for same key.
        if !hasDismissedHeroChecklist, completedCount < totalCount {
            VStack(alignment: .leading, spacing: 12) {
                headerRow
                progressRow
                Divider()
                    .overlay(Color.secondary.opacity(0.12))
                ForEach(Array(incompleteItems.enumerated()), id: \.element.item) { index, entry in
                    checklistRow(for: entry.item, index: index)
                    if index < incompleteItems.count - 1 {
                        Divider()
                            .overlay(Color.secondary.opacity(0.08))
                    }
                }
            }
            .padding(DesignSystemConstants.Padding.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .strokeBorder(Color(DesignSystemConstants.Colors.gold).opacity(0.30), lineWidth: 1)
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("heroChecklist.card")
        }
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your hero checklist")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("heroChecklist.title")
                Text("\(completedCount)/\(totalCount) done — let's get you set up!")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("heroChecklist.subtitle")
            }
            Spacer(minLength: 8)
            Button {
                HapticsService.lightImpact()
                hasDismissedHeroChecklist = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss checklist")
            .accessibilityIdentifier("heroChecklist.dismissButton")
        }
    }

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(completedCount)/\(totalCount) completed")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((Double(completedCount) / Double(totalCount) * 100).rounded()))%")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
            }
            ProgressView(value: Double(completedCount), total: Double(totalCount))
                .tint(Color(DesignSystemConstants.Colors.primaryGreen))
                .accessibilityIdentifier("heroChecklist.progress")
        }
    }

    private func checklistRow(for item: ChecklistItem, index: Int) -> some View {
        let number = index + 1
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.12))
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.25), lineWidth: 1))
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle(for: item))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(rowSubtitle(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if item == .buckets {
                    HStack(spacing: 6) {
                        bucketPill(label: "Spend \(profileRow.splitPercentSpend)%")
                        bucketPill(label: "Short \(profileRow.splitPercentShort)%")
                        bucketPill(label: "Long \(profileRow.splitPercentLong)%")
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            Button {
                HapticsService.lightImpact()
                onAction(item)
            } label: {
                HStack(spacing: 4) {
                    if item == .notifications {
                        Text("Turn On")
                            .font(.caption.weight(.bold))
                    }
                    Image(systemName: item == .notifications ? "bell.badge.fill" : "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                .padding(.horizontal, item == .notifications ? 10 : 8)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color(DesignSystemConstants.Colors.accentBlue).opacity(item == .notifications ? 0.14 : 0.10))
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("heroChecklist.action-\(item.rawValue)")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            HapticsService.lightImpact()
            onAction(item)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("heroChecklist.row-\(item.rawValue)")
    }

    private func bucketPill(label: String) -> some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.18), lineWidth: 1))
    }

    private func rowTitle(for item: ChecklistItem) -> String {
        switch item {
        case .notifications: "Turn on alerts"
        case .buckets: "Set your 3 buckets"
        case .firstQuest: "Complete a quest"
        case .firstGoal: "Create a wishlist goal"
        }
    }

    private func rowSubtitle(for item: ChecklistItem) -> String {
        switch item {
        case .notifications: "Turn on alerts so you know when quests are approved"
        case .buckets: "Set your 3 buckets so allowance fills your goals"
        case .firstQuest: FlavorTextProvider.questCompleteHint
        case .firstGoal: "Create a wishlist goal for Short or Long save"
        }
    }
}
