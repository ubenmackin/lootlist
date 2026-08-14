//
//  GuildPayoutDefaultsSectionView.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import SwiftUI

struct GuildPayoutDefaultsSectionView: View {
    @Environment(AppState.self) private var appState
    @Environment(FamilyService.self) private var familyService
    @Environment(ToastManager.self) private var toastManager

    @Binding var isPayoutPolicyExpanded: Bool

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
                    Picker("Payout Day", selection: Binding(
                        get: { appState.family?.payoutDay ?? .sunday },
                        set: { newDay in
                            if let family = appState.family {
                                Task {
                                    do {
                                        try await familyService.updatePayoutDay(family: family, day: newDay)
                                    } catch {
                                        toastManager.show(
                                            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                                            type: .error
                                        )
                                    }
                                }
                            }
                        }
                    )) {
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
                                Text(appState.family?.payoutPolicy.displayName ?? "Pay Per Quest (Standard)")
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
    }

    private func familyPayoutPolicyOptionRow(policy: PayoutPolicy) -> some View {
        let currentPolicy = appState.family?.payoutPolicy ?? .perQuest
        let isSelected = currentPolicy == policy
        return Button {
            if !isSelected, let family = appState.family {
                Task {
                    do {
                        _ = try await familyService.updatePayoutPolicy(family: family, policy: policy)
                    } catch {
                        toastManager.show(
                            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                            type: .error
                        )
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

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}
