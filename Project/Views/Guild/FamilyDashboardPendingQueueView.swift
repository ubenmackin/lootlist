//
//  FamilyDashboardPendingQueueView.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import SwiftData
import SwiftUI

/// Pending approval queue extracted from FamilyDashboardView so the dashboard
/// composes focused sections with no logic change.
struct FamilyDashboardPendingQueueView: View {
    let pending: [QuestCompletionCache]
    let profiles: [ProfileCache]
    let quests: [QuestCache]
    let viewerIsHero: Bool
    let onApprove: (QuestCompletionCache) -> Void
    let onReject: (QuestCompletionCache) -> Void

    var body: some View {
        if !pending.isEmpty, !viewerIsHero {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("PENDING APPROVAL QUEUE") {
                    Text("\(pending.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color(DesignSystemConstants.Colors.pendingAmber))
                        )
                }

                VStack(spacing: 8) {
                    ForEach(pending, id: \.recordName) { completion in
                        row(completion)
                    }
                }
            }
            .padding(DesignSystemConstants.Padding.standard)
            .background(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.40), lineWidth: 1.5)
            )
            .id("pendingQueueAnchor")
        }
    }

    private func row(_ completion: QuestCompletionCache) -> some View {
        let heroName = profiles.first { $0.recordName == completion.completerRecordName }?.displayName ?? "Hero"
        let quest = quests.first { $0.recordName == completion.questRecordName }
        let questName = quest?.questName ?? "Quest"
        let goldAmount = quest?.goldReward ?? 0
        let scheduleLabel = quest?.scheduleTypeEnum?.displayName ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            FamilyDashboardPendingRowHeader(questName: questName, heroName: heroName, scheduleLabel: scheduleLabel)
            HStack(spacing: 10) {
                rejectButton(completion: completion, questName: questName)
                approveButton(completion: completion, questName: questName, goldAmount: goldAmount)
            }
        }
        .padding(DesignSystemConstants.Padding.small)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .hoverEffect(.highlight)
        .contextMenu {
            Button {
                onApprove(completion)
            } label: {
                Label("Approve", systemImage: "checkmark.circle.fill")
            }
            Button(role: .destructive) {
                onReject(completion)
            } label: {
                Label("Reject", systemImage: "xmark.circle.fill")
            }
        }
    }

    private func rejectButton(completion: QuestCompletionCache, questName: String) -> some View {
        Button {
            onReject(completion)
        } label: {
            Text("Reject")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color(DesignSystemConstants.Colors.dangerRed).opacity(0.12))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reject \(questName)")
        .accessibilityIdentifier("dashboard.rejectButton-\(completion.recordName)")
    }

    private func approveButton(completion: QuestCompletionCache, questName: String, goldAmount: Int64) -> some View {
        let showsAmount = goldAmount > 0
        let approvalLabel = CurrencyFormatter.string(goldAmount)
        return Button {
            onApprove(completion)
        } label: {
            HStack(spacing: 4) {
                Text("Approve")
                if showsAmount {
                    Text(approvalLabel)
                        .font(.caption.weight(.bold).monospacedDigit())
                }
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color(DesignSystemConstants.Colors.primaryGreen))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Approve \(questName) for \(approvalLabel)")
        .accessibilityIdentifier("dashboard.approveButton-\(completion.recordName)")
    }
}
