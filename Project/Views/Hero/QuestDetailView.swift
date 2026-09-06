//
//  QuestDetailView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import os
import SwiftData
import SwiftUI

struct QuestDetailView: View {
    let quest: QuestCache
    let initialLog: QuestCompletionCache?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestDetail")

    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(ToastManager.self) private var toastManager: ToastManager?

    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedTemplates: [QuestTemplateCache]

    @State private var isCompleting: Bool = false
    @State private var showQuestHelp: Bool = false

    private var template: QuestTemplateCache? {
        cachedTemplates.first(where: { $0.recordName == quest.templateRecordName })
    }

    private var templatesByID: [String: QuestTemplateCache] {
        SpecificDaysHelper.templatesByID(cachedTemplates)
    }

    private var targetCount: Int {
        SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
    }

    private var allLogs: [QuestCompletionCache] {
        cachedCompletions
    }

    private var latestLog: QuestCompletionCache? {
        allLogs.first ?? initialLog
    }

    private var approvedLogs: [QuestCompletionCache] {
        allLogs.filter { $0.verificationStatusEnum == .autoApproved || $0.verificationStatusEnum == .verified }
    }

    private var approvedCount: Int {
        approvedLogs.count
    }

    private var isFullyCompleted: Bool {
        GoldCalculation.isFullyCompleted(quest: quest, approvedCount: approvedCount, effectiveTarget: targetCount)
    }

    init(quest: QuestCache, initialLog: QuestCompletionCache? = nil) {
        self.quest = quest
        self.initialLog = initialLog

        let targetFamily = quest.familyRecordName
        let questName = quest.recordName
        FamilyScopeValidator.validateOrFault(targetFamily: targetFamily, viewName: "QuestDetailView")

        if targetFamily.isEmpty {
            // WHY: fail-closed — empty scope must return zero rows via indexed predicate, never an unscoped scan across families.
            let emptyFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == "__empty__" }
            _cachedCompletions = Query(
                filter: emptyFilter,
                sort: \QuestCompletionCache.completedDate,
                order: .reverse
            )
        } else {
            // WHY: predicate pushdown on familyRecordName+questRecordName index — cross-family isolation at fetch layer.
            let filter = #Predicate<QuestCompletionCache> {
                $0.familyRecordName == targetFamily && $0.questRecordName == questName
            }
            _cachedCompletions = Query(
                filter: filter,
                sort: \QuestCompletionCache.completedDate,
                order: .reverse
            )
        }
        let targetTemplate = quest.templateRecordName
        if targetFamily.isEmpty {
            // WHY: fail-closed — empty scope must return zero rows via indexed predicate, never an unscoped scan across families.
            let emptyTemplateFilter = #Predicate<QuestTemplateCache> { $0.familyRecordName == "__empty__" }
            _cachedTemplates = Query(filter: emptyTemplateFilter, sort: \QuestTemplateCache.name)
        } else {
            let templateFilter = #Predicate<QuestTemplateCache> {
                $0.familyRecordName == targetFamily && $0.recordName == targetTemplate
            }
            _cachedTemplates = Query(filter: templateFilter, sort: \QuestTemplateCache.name)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                rewardsCard
                approvalCard
                if targetCount > 1 {
                    progressCard
                }
                completeButton
                if !allLogs.isEmpty {
                    logsSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(DesignSystemConstants.Colors.background))
        .scrollContentBackground(.hidden)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showQuestHelp = true } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityIdentifier("questHelp.button")
            }
        }
        .sheet(isPresented: $showQuestHelp) {
            QuestHelpSheetView()
        }
    }

    private var header: some View {
        let titleText = quest.questName == "Quest" ? (template?.name ?? "Quest") : quest.questName
        let descText = if let desc = quest.descriptionText, !desc.isEmpty {
            desc
        } else {
            template?.templateDescription ?? ""
        }

        return VStack(alignment: .leading, spacing: 8) {
            Text(titleText)
                .font(.title2.bold())
            if !descText.isEmpty {
                Text(descText)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
    }

    private var rewardsCard: some View {
        HStack(spacing: 18) {
            rewardPill(icon: "banknote",
                       label: CurrencyFormatter.string(quest.goldReward),
                       tint: Color(DesignSystemConstants.Colors.pendingAmber))
            if FeatureFlags.rpgImmersive {
                rewardPill(icon: "sparkles",
                           label: FlavorTextProvider.rewardTierName(for: quest.rarityEnum ?? .common),
                           tint: (quest.rarityEnum ?? .common).color)
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
    }

    private func rewardPill(icon: String, label: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(label)
                .font(.headline)
                .monospacedDigit()
        }
    }

    private var approvalCard: some View {
        HStack(spacing: 8) {
            Image(systemName: (quest.approvalModeEnum ?? .autoApprove).iconSystemName)
                .foregroundStyle((quest.approvalModeEnum ?? .autoApprove) == .parentVerify ? Color(DesignSystemConstants.Colors.accentBlue) :
                    Color(DesignSystemConstants.Colors.primaryGreen))
            Text((quest.approvalModeEnum ?? .autoApprove).displayName)
                .font(.subheadline)
            Spacer()
            Image(systemName: (quest.scheduleTypeEnum ?? .weeklyFlexible).iconSystemName)
                .foregroundStyle(.secondary)
            Text((quest.scheduleTypeEnum ?? .weeklyFlexible).displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
    }

    // MARK: - Multi-Completion Progress Card

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Progress: \(approvedCount)/\(targetCount) completed")
                .font(.headline)

            ProgressView(value: Double(approvedCount), total: Double(targetCount))
                .tint(isFullyCompleted ? Color(DesignSystemConstants.Colors.primaryGreen) : Color(DesignSystemConstants.Colors.accentBlue))

            if isFullyCompleted {
                Label("All completions logged!", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
    }

    // MARK: - Logs Section

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(targetCount > 1 ? "Completion Logs" : "Status")
                .font(.headline)

            ForEach(allLogs.sorted(by: { $0.completedDate < $1.completedDate }), id: \.id) { log in
                statusCard(log: log)
            }
        }
    }

    private func statusCard(log: QuestCompletionCache) -> some View {
        let status = log.verificationStatusEnum ?? .autoApproved
        return HStack(spacing: 8) {
            Image(systemName: status.iconSystemName)
                .foregroundStyle(status.tintColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.detailedDescription)
                    .font(.subheadline.bold())
                Text(log.completedDate, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(status.tintColor.opacity(0.12))
        )
    }

    private var hasPendingLog: Bool {
        (quest.approvalModeEnum ?? .autoApprove) == .parentVerify && allLogs.contains(where: { $0.verificationStatusEnum == .pending })
    }

    private var pendingLog: QuestCompletionCache? {
        allLogs.first(where: { $0.verificationStatusEnum == .pending })
    }

    private var completeButton: some View {
        VStack(spacing: 12) {
            Button {
                Task { await completeQuest() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isFullyCompleted ? "checkmark.seal.fill" : (hasPendingLog ? "hourglass" : "checkmark.circle.fill"))
                    Text(completeButtonLabel)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(isFullyCompleted ? Color(DesignSystemConstants.Colors.primaryGreen) :
                (hasPendingLog ? Color(DesignSystemConstants.Colors.accentBlue) : Color(DesignSystemConstants.Colors.primaryGreen)))
            .disabled(completeButtonDisabled)
            .opacity(completeButtonDisabled ? 0.5 : 1)

            if hasPendingLog, let logToWithdraw = pendingLog {
                Button(role: .destructive) {
                    Task { await withdrawCompletion(logToWithdraw) }
                } label: {
                    Label("Unsubmit Completion", systemImage: "arrow.uturn.backward.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .disabled(isCompleting)
            }

            if !isFullyCompleted {
                Text(FlavorTextProvider.questCompleteTip(rewardText: CurrencyFormatter.string(quest.goldReward)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var completeButtonLabel: String {
        if isFullyCompleted {
            return "Completed"
        }
        if targetCount > 1 {
            let pending = allLogs.filter { $0.verificationStatusEnum == .pending }.count
            if pending > 0 {
                return "Awaiting Verification (\(approvedCount)/\(targetCount))"
            }
            return "Log Completion (\(approvedCount + 1)/\(targetCount))"
        }
        if let log = latestLog {
            switch log.verificationStatusEnum ?? .autoApproved {
            case .autoApproved, .verified: return "Completed"
            case .pending: return "Awaiting Verification"
            case .rejected, .withdrawn: return "Complete (Try Again)"
            }
        }
        return "Complete"
    }

    private var completeButtonDisabled: Bool {
        if isFullyCompleted {
            return true
        }
        if hasPendingLog {
            return true
        }
        if targetCount > 1 {
            return canSubmitAnotherCompletion
        }
        if let log = latestLog {
            switch log.verificationStatusEnum ?? .autoApproved {
            case .autoApproved, .verified, .pending: return true
            case .rejected, .withdrawn: return isCompleting
            }
        }
        return isCompleting
    }

    /// Disables completion when submission is in flight or verified slots are filled.
    private var canSubmitAnotherCompletion: Bool {
        isCompleting || GoldCalculation.nonRejectedLogsReachTarget(quest: quest, nonRejectedCount: nonRejected, effectiveTarget: targetCount)
    }

    private var nonRejected: Int {
        allLogs.filter { ($0.verificationStatusEnum ?? .autoApproved).countsTowardCompletion }.count
    }

    private func completeQuest() async {
        guard let profile = appState.currentProfile else {
            toastManager?.show(message: "No active hero profile.", type: .error)
            return
        }
        isCompleting = true
        defer { isCompleting = false }
        do {
            _ = try await questService.markComplete(quest: quest, by: profile)
        } catch let questError as QuestServiceError {
            toastManager?.show(message: questError.localizedDescription, type: .error)
        } catch {
            logger.error("Failed to complete quest: \(error, privacy: .private)")
            toastManager?.show(message: "Could not complete the quest. Please try again.", type: .error)
        }
    }

    private func withdrawCompletion(_ log: QuestCompletionCache) async {
        guard let profile = appState.currentProfile else { return }
        isCompleting = true
        defer { isCompleting = false }
        do {
            try await questService.withdrawCompletion(questLog: log, by: profile)
            toastManager?.show(message: "Completion unsubmitted.", type: .info)
        } catch {
            logger.error("Failed to unsubmit completion: \(error, privacy: .private)")
            toastManager?.show(message: "Could not unsubmit the quest. Please try again.", type: .error)
        }
    }
}
