import CloudKit
import SwiftUI

struct QuestDetailView: View {
    let quest: Quest

    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService

    @State private var latestLog: QuestCompletion?
    @State private var template: QuestTemplate?
    @State private var isCompleting: Bool = false
    @State private var error: String?
    @State private var isErrorPresented: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                rewardsCard
                approvalCard
                if let log = latestLog {
                    statusCard(log: log)
                }
                slainButton
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
        VStack(alignment: .leading, spacing: 8) {
            Text(template?.name ?? "Quest")
                .font(.title2.bold())
            Text(template?.description ?? "")
                .font(.body)
                .foregroundStyle(.secondary)
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
                       label: String(format: "%.2f", quest.goldReward),
                       tint: .yellow)
            rewardPill(icon: "star.fill",
                       label: "\(quest.xpReward) XP",
                       tint: .purple)
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

    private func statusCard(log: QuestCompletion) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon(log.verificationStatus))
                .foregroundStyle(statusColor(log.verificationStatus))
            Text(statusLabel(log.verificationStatus))
                .font(.subheadline.bold())
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(statusColor(log.verificationStatus).opacity(0.12))
        )
    }

    private var slainButton: some View {
        Button {
            Task { await slain() }
        } label: {
            HStack {
                Image(systemName: "sword.fill")
                Text(slainButtonLabel)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.red)
        .disabled(slainButtonDisabled)
        .opacity(slainButtonDisabled ? 0.6 : 1)
    }

    private var slainButtonLabel: String {
        guard let log = latestLog else { return "Slain! ⚔️" }
        switch log.verificationStatus {
        case .autoApproved, .verified: return "Slain ⚔️"
        case .pending: return "Awaiting Verification"
        case .rejected: return "Slain! ⚔️ (Try Again)"
        }
    }

    private var slainButtonDisabled: Bool {
        guard let log = latestLog else { return isCompleting }
        switch log.verificationStatus {
        case .autoApproved, .verified, .pending: return true
        case .rejected: return isCompleting
        }
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

    private func load() async {
        do {
            template = try await questService.cloudKitReference.fetch(
                QuestTemplate.self, id: quest.template.recordID
            )
        } catch {
            template = nil
        }

        do {
            let logs = try await questService.fetchQuestLogs(forQuest: quest)
            latestLog = logs.first
        } catch {
            latestLog = nil
        }
    }

    private func slain() async {
        guard let profile = appState.currentProfile else {
            error = "No active hero profile."
            isErrorPresented = true
            return
        }
        isCompleting = true
        defer { isCompleting = false }
        do {
            latestLog = try await questService.markComplete(quest: quest, by: profile)
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
        case .alreadyCompleted: "This quest has already been slain."
        case let .alreadyResolved(status): "This quest is already \(status)."
        case let .missingRecord(status): "A required record could not be loaded: \(status)"
        }
    }
}
