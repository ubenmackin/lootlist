//
//  GuildPayoutDefaultsSectionView.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import os
import SwiftUI

struct GuildPayoutDefaultsSectionView: View {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "GuildPayoutDefaults")

    @Environment(AppState.self) private var appState
    @Environment(FamilyService.self) private var familyService
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @Binding var isPayoutPolicyExpanded: Bool

    @State private var selectedPolicy: PayoutPolicy = .perQuest
    @State private var saveTask: Task<Void, Never>?
    @State private var saveTaskDay: Task<Void, Never>?
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allowance & Payout Defaults")
                .font(.headline)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 14) {
                // Payout Day Picker
                HStack {
                    Label("Weekly Payout Day", systemImage: "calendar.badge.clock")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker("Payout Day", selection: payoutDayBinding) {
                        ForEach(PayoutDay.allCases) { day in
                            Text(day.displayName).tag(day)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .padding(14)
            .background(cardBackground)

            // Collapsible Default Payout Policy Radio Cards
            VStack(alignment: .leading, spacing: 10) {
                DisclosureGroup(
                    isExpanded: $isPayoutPolicyExpanded,
                    content: {
                        VStack(spacing: 10) {
                            ForEach(PayoutPolicy.allCases, id: \.self) { policy in
                                familyPayoutPolicyOptionRow(policy: policy)
                            }
                        }
                        .padding(.top, 10)
                    },
                    label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Default Payout Policy")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.primary)
                                Text(selectedPolicy.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                )
            }
            .padding(14)
            .background(cardBackground)
        }
        .padding(.horizontal)
        .onAppear {
            selectedPolicy = appState.family?.payoutPolicy ?? .perQuest
        }
        .onChange(of: appState.family?.payoutPolicy) { _, newPolicy in
            if let newPolicy {
                selectedPolicy = newPolicy
            }
        }
        .onChange(of: actionError) { _, error in
            if let error {
                toastManager.show(message: error, type: .error)
                actionError = nil
            }
        }
    }

    private func familyPayoutPolicyOptionRow(policy: PayoutPolicy) -> some View {
        let isSelected = selectedPolicy == policy
        return Button {
            if !isSelected, let family = appState.family {
                saveTask?.cancel()
                let previousPolicy = selectedPolicy
                withAnimation(accessibilityReduceMotion ? .none : .snappy(duration: 0.2, extraBounce: 0)) {
                    selectedPolicy = policy
                }
                saveTask = Task { @MainActor in
                    do {
                        try await Task.sleep(nanoseconds: 350_000_000)
                        try Task.checkCancellation()
                        _ = try await familyService.updatePayoutPolicy(family: family, policy: policy)
                    } catch {
                        guard !Task.isCancelled else { return }
                        withAnimation(accessibilityReduceMotion ? .none : .snappy(duration: 0.2, extraBounce: 0)) {
                            selectedPolicy = previousPolicy
                        }
                        logger.error("Failed to update payout policy: \(error, privacy: .private)")
                        actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: policy.iconSystemName)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        Text(policy.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                    }

                    Text(policy.subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var payoutDayBinding: Binding<PayoutDay> {
        Binding(
            get: { appState.family?.payoutDay ?? .sunday },
            set: { newDay in
                if let family = appState.family {
                    saveTaskDay?.cancel()
                    saveTaskDay = Task { @MainActor in
                        do {
                            try await Task.sleep(nanoseconds: 350_000_000)
                            try Task.checkCancellation()
                            try await familyService.updatePayoutDay(family: family, day: newDay)
                        } catch {
                            guard !Task.isCancelled else { return }
                            logger.error("Failed to update payout day: \(error, privacy: .private)")
                            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    }
                }
            }
        )
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}
