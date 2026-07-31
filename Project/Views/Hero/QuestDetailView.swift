//
//  QuestDetailView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import SwiftUI

struct QuestDetailView: View {
    let quest: Quest
    let initialLog: QuestCompletion?

    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(CacheService.self) private var cacheService: CacheService?

    @State private var allLogs: [QuestCompletion] = []
    @State private var latestLog: QuestCompletion?
    @State private var template: QuestTemplate?
    @State private var isCompleting: Bool = false
    @State private var isLoadingLog: Bool = false
    @State private var error: String?
    @State private var isErrorPresented: Bool = false

    private var targetCount: Int {
        max(1, quest.targetCount)
    }

    private var approvedLogs: [QuestCompletion] {
        allLogs.filter { $0.verificationStatus == .autoApproved || $0.verificationStatus == .verified }
    }

    private var approvedCount: Int {
        approvedLogs.count
    }

    private var isFullyCompleted: Bool {
        approvedCount >= targetCount
    }

    init(quest: Quest, initialLog: QuestCompletion? = nil) {
        self.quest = quest
        self.initialLog = initialLog
        _latestLog = State(initialValue: initialLog)
        if let initialLog {
            _allLogs = State(initialValue: [initialLog])
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
                if !allLogs.isEmpty {
                    logsSection
                }
                completeButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .containerRelativeFrame([.vertical])
        }
        .background(Color(.systemGroupedBackground))
        .scrollContentBackground(.hidden)
        .navigationTitle("Quest")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
        .alert("Couldn't update quest", isPresented: $isErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            if let error {
                Text(error)
            }
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
            rewardPill(icon: "dollarsign.circle.fill",
                       label: String(format: "%.2f Gold", quest.goldReward),
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

    private var completeButton: some View {
        Button {
            Task { await completeQuest() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                Text(completeButtonLabel)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.green)
        .disabled(completeButtonDisabled)
        .opacity(completeButtonDisabled ? 0.6 : 1)
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
            case .rejected: return "Complete (Try Again)"
            }
        }
        return (isLoadingLog && latestLog == nil) ? "Loading..." : "Complete"
    }

    private var completeButtonDisabled: Bool {
        if isFullyCompleted {
            return true
        }
        if targetCount > 1 {
            let nonRejected = allLogs.filter { $0.verificationStatus != .rejected }.count
            return isCompleting || nonRejected >= targetCount
        }
        if let log = latestLog {
            switch log.verificationStatus {
            case .autoApproved, .verified, .pending: return true
            case .rejected: return isCompleting
            }
        }
        return isCompleting || (isLoadingLog && latestLog == nil)
    }

    private func statusIcon(_ status: VerificationStatus) -> String {
        switch status {
        case .autoApproved: "checkmark.seal.fill"
        case .verified: "checkmark.seal.fill"
        case .pending: "hourglass"
        case .rejected: "xmark.octagon.fill"
        }
    }

    private func statusColor(_ status: VerificationStatus) -> Color {
        switch status {
        case .autoApproved: .green
        case .verified: .green
        case .pending: .orange
        case .rejected: .red
        }
    }

    private func statusLabel(_ status: VerificationStatus) -> String {
        switch status {
        case .autoApproved: "Auto-approved — gold & XP earned"
        case .verified: "Verified by parent — gold & XP earned"
        case .pending: "Awaiting parent verification"
        case .rejected: "Rejected by parent — try again"
        }
    }

    private func load(forceRefresh: Bool = false) async {
        isLoadingLog = true
        defer { isLoadingLog = false }

        if !forceRefresh, let cacheService {
            let familyName = quest.family.recordID.recordName
            let templateName = quest.template.recordID.recordName
            if let cached = cacheService.fetchQuestTemplates(family: familyName)
                .first(where: { $0.recordName == templateName })
            {
                template = cached.toQuestTemplate(zoneID: questService.cloudKitReference.resolvedZoneID)
            }
        } else {
            do {
                template = try await questService.cloudKitReference.fetch(
                    QuestTemplate.self, id: quest.template.recordID
                )
            } catch {
                template = nil
            }
        }

        do {
            // On forceRefresh (post-mutation), bypass SwiftData to reconcile
            // against CloudKit's authoritative log set and prevent duplicate
            // completions from another device.
            let logs = try await questService.fetchQuestLogs(forQuest: quest, useCache: !forceRefresh)
            allLogs = logs
            if let fetched = logs.first {
                latestLog = fetched
            }
        } catch {
            // Keep existing log if fetch encounters error
        }
    }

    private func completeQuest() async {
        guard let profile = appState.currentProfile else {
            error = "No active hero profile."
            isErrorPresented = true
            return
        }
        isCompleting = true
        defer { isCompleting = false }
        do {
            let newLog = try await questService.markComplete(quest: quest, by: profile)
            latestLog = newLog
            allLogs.append(newLog)
            // Reconcile local state against CloudKit's authoritative log set before
            // the user can tap the next slot. Awaits so the multi-completion disable
            // check reads the freshly-loaded `allLogs` and cannot desync by one tap.
            await load(forceRefresh: true)
        } catch let questError as QuestServiceError {
            self.error = questError.localizedDescription
            self.isErrorPresented = true
        } catch {
            self.error = error.localizedDescription
            isErrorPresented = true
        }
    }
}

extension QuestServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingSession: "Sign in to iCloud to continue."
        case .alreadyCompleted: "This quest has already been completed."
        case let .alreadyResolved(status): "This quest is already \(status)."
        case let .missingRecord(status): "A required record could not be loaded: \(status)"
        }
    }
}
