//
//  QuestDetailView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import os
import SwiftData
import SwiftUI

struct QuestDetailView: View {
    let quest: Quest
    let initialLog: QuestCompletion?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestDetail")

    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(ToastManager.self) private var toastManager: ToastManager?

    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedTemplates: [QuestTemplateCache]

    @State private var template: QuestTemplate?
    @State private var isCompleting: Bool = false
    @State private var isLoadingLog: Bool = false

    private var targetCount: Int {
        max(1, quest.targetCount)
    }

    private var allLogs: [QuestCompletion] {
        let zoneID = questService.cloudKitReference.resolvedZoneID
        return cachedCompletions.map { $0.toQuestCompletion(zoneID: zoneID) }
    }

    private var latestLog: QuestCompletion? {
        allLogs.first ?? initialLog
    }

    private var approvedLogs: [QuestCompletion] {
        allLogs.filter { $0.verificationStatus == .autoApproved || $0.verificationStatus == .verified }
    }

    private var approvedCount: Int {
        approvedLogs.count
    }

    private var isFullyCompleted: Bool {
        GoldCalculation.isFullyCompleted(quest: quest, approvedCount: approvedCount)
    }

    init(quest: Quest, initialLog: QuestCompletion? = nil) {
        self.quest = quest
        self.initialLog = initialLog

        let questName = quest.id.recordName
        let filter = #Predicate<QuestCompletionCache> {
            $0.questRecordName == questName
        }
        _cachedCompletions = Query(
            filter: filter,
            sort: \QuestCompletionCache.completedDate,
            order: .reverse
        )

        // Scope templates to the quest's family at the SwiftData store layer.
        let familyName = quest.family.recordID.recordName
        let templateFilter = #Predicate<QuestTemplateCache> {
            $0.familyRecordName == familyName
        }
        _cachedTemplates = Query(
            filter: templateFilter
        )
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
        .background(Color(.systemGroupedBackground))
        .scrollContentBackground(.hidden)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
    }

    private var header: some View {
        let titleText = quest.displayName == "Quest" ? (template?.name ?? "Quest") : quest.displayName
        let descText = quest.displayDescription.isEmpty ? (template?.description ?? "") : quest.displayDescription

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
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var rewardsCard: some View {
        HStack(spacing: 18) {
            rewardPill(icon: "banknote",
                       label: CurrencyFormatter.string(quest.goldReward),
                       tint: .yellow)
            rewardPill(icon: quest.rarity.iconSystemName,
                       label: "\(quest.rarity.rawValue) (\(quest.xpReward) XP)",
                       tint: quest.rarity.color)
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemGroupedBackground))
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
            Image(systemName: quest.approvalMode.iconSystemName)
                .foregroundStyle(quest.approvalMode == .parentVerify ? .indigo : .green)
            Text(quest.approvalMode.displayName)
                .font(.subheadline)
            Spacer()
            Image(systemName: quest.scheduleType.iconSystemName)
                .foregroundStyle(.secondary)
            Text(quest.scheduleType.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Multi-Completion Progress Card

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Progress: \(approvedCount)/\(targetCount) completed")
                .font(.headline)

            ProgressView(value: Double(approvedCount), total: Double(targetCount))
                .tint(isFullyCompleted ? .green : .accentColor)

            if isFullyCompleted {
                Label("All completions logged!", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemGroupedBackground))
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

    private func statusCard(log: QuestCompletion) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon(log.verificationStatus))
                .foregroundStyle(statusColor(log.verificationStatus))
            VStack(alignment: .leading, spacing: 2) {
                Text(statusLabel(log.verificationStatus))
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
                .fill(statusColor(log.verificationStatus).opacity(0.12))
        )
    }

    private var hasPendingLog: Bool {
        quest.approvalMode == .parentVerify && allLogs.contains(where: { $0.verificationStatus == .pending })
    }

    private var pendingLog: QuestCompletion? {
        allLogs.first(where: { $0.verificationStatus == .pending })
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
            .tint(isFullyCompleted ? .green : (hasPendingLog ? .purple : .green))
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
        }
    }

    private var completeButtonLabel: String {
        if isFullyCompleted {
            return "Completed"
        }
        if targetCount > 1 {
            let pending = allLogs.filter { $0.verificationStatus == .pending }.count
            if pending > 0 {
                return "Awaiting Verification (\(approvedCount)/\(targetCount))"
            }
            return "Log Completion (\(approvedCount + 1)/\(targetCount))"
        }
        if let log = latestLog {
            switch log.verificationStatus {
            case .autoApproved, .verified: return "Completed"
            case .pending: return "Awaiting Verification"
            case .rejected, .withdrawn: return "Complete (Try Again)"
            }
        }
        return (isLoadingLog && latestLog == nil) ? "Loading..." : "Complete"
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
            switch log.verificationStatus {
            case .autoApproved, .verified, .pending: return true
            case .rejected, .withdrawn: return isCompleting
            }
        }
        return isCompleting || (isLoadingLog && latestLog == nil)
    }

    /// Disables the multi-completion button when a submission is already in
    /// flight or non-rejected logs already occupy every completion slot.
    /// Pending logs never reach this gate — `completeButtonDisabled` returns
    /// early for them — so only approved/verified logs are counted here.
    private var canSubmitAnotherCompletion: Bool {
        isCompleting || GoldCalculation.nonRejectedLogsReachTarget(quest: quest, nonRejectedCount: nonRejected)
    }

    private var nonRejected: Int {
        allLogs.filter(\.verificationStatus.countsTowardCompletion).count
    }

    private func statusIcon(_ status: VerificationStatus) -> String {
        switch status {
        case .autoApproved: "checkmark.seal.fill"
        case .verified: "checkmark.seal.fill"
        case .pending: "hourglass"
        case .rejected: "xmark.octagon.fill"
        case .withdrawn: "arrow.uturn.backward.circle.fill"
        }
    }

    private func statusColor(_ status: VerificationStatus) -> Color {
        switch status {
        case .autoApproved: .green
        case .verified: .green
        case .pending: .orange
        case .rejected: .red
        case .withdrawn: .gray
        }
    }

    private func statusLabel(_ status: VerificationStatus) -> String {
        switch status {
        case .autoApproved: "Auto-approved — money & XP earned"
        case .verified: "Verified by parent — money & XP earned"
        case .pending: "Awaiting parent verification"
        case .rejected: "Rejected by parent — try again"
        case .withdrawn: "Unsubmitted — try again"
        }
    }

    private func load() async {
        isLoadingLog = true
        defer { isLoadingLog = false }

        let templateName = quest.template.recordID.recordName
        if let cached = cachedTemplates.first(where: { $0.recordName == templateName }) {
            template = cached.toQuestTemplate(zoneID: questService.cloudKitReference.resolvedZoneID)
        } else if let cachedDeactivated = questService.cacheService?.fetchQuestTemplate(recordName: templateName) {
            template = cachedDeactivated.toQuestTemplate(zoneID: questService.cloudKitReference.resolvedZoneID)
        } else {
            do {
                template = try await questService.cloudKitReference.fetch(
                    QuestTemplate.self, id: quest.template.recordID
                )
            } catch {
                template = nil
            }
        }
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

    private func withdrawCompletion(_ log: QuestCompletion) async {
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

extension QuestServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingSession: "Sign in to iCloud to continue."
        case .alreadyCompleted: "This quest has already been completed."
        case .alreadyInFlight: "This quest is already being completed."
        case let .alreadyResolved(status): "This quest is already \(status)."
        case let .missingRecord(status): "A required record could not be loaded: \(status)"
        }
    }
}
