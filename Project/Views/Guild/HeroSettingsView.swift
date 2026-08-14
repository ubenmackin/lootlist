//
//  HeroSettingsView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import os
import SwiftUI

struct HeroSettingsView: View {
    let hero: Profile

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "HeroSettings")

    @Environment(ToastManager.self) private var toastManager
    @Environment(AppState.self) private var appState
    @Environment(FamilyService.self) private var familyService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPolicy: PayoutPolicy
    @State private var selectedDayOverride: PayoutDay?
    @State private var isSaving: Bool = false
    @State private var actionError: String?

    init(hero: Profile) {
        self.hero = hero
        _selectedPolicy = State(initialValue: hero.payoutPolicy)
        _selectedDayOverride = State(initialValue: hero.payoutDay)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Hero Header Card
                    heroHeaderCard

                    // Payout Day Override
                    payoutDayOverrideSection

                    // Payout Policy Section with Radio Cards
                    payoutPolicySection
                }
                .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("\(hero.displayName)'s Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onChange(of: actionError) { _, newError in
                if let error = newError {
                    toastManager.show(message: error, type: .error)
                    actionError = nil
                }
            }
            .toastOverlay()
        }
    }

    // MARK: - Hero Header Card

    private var heroHeaderCard: some View {
        HStack(spacing: 16) {
            avatarView

            VStack(alignment: .leading, spacing: 4) {
                Text(hero.displayName)
                    .font(.title3.weight(.bold))

                HStack(spacing: 6) {
                    Text("Level \(hero.level)")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)

                    Text(hero.effectiveClassDisplay)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(16)
        .background(cardBackground)
        .padding(.horizontal)
    }

    private var avatarView: some View {
        ProfileAvatarView(profile: hero)
    }

    // MARK: - Payout Day Override Section

    private var payoutDayOverrideSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weekly Payout Day")
                .font(.headline)
                .padding(.horizontal, 4)

            HStack {
                Label("Hero Payout Day", systemImage: "calendar.badge.clock")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Payout Day", selection: Binding(
                    get: { selectedDayOverride },
                    set: { newDay in
                        let previous = selectedDayOverride
                        selectedDayOverride = newDay
                        actionError = nil
                        Task {
                            do {
                                _ = try await familyService.updateProfilePayoutDay(profile: hero, day: newDay)
                            } catch {
                                selectedDayOverride = previous
                                logger.error("Failed to update payout day: \(error, privacy: .private)")
                                actionError = "Could not update payout day. Please try again."
                            }
                        }
                    }
                )) {
                    Text("Default").tag(PayoutDay?.none)
                    Divider()
                    ForEach(PayoutDay.allCases) { day in
                        Text(day.displayName).tag(PayoutDay?.some(day))
                    }
                }
                .pickerStyle(.menu)
            }
            .padding(14)
            .background(cardBackground)
        }
        .padding(.horizontal)
    }

    // MARK: - Payout Policy Radio Section

    private var payoutPolicySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allowance Payout Rule")
                .font(.headline)
                .padding(.horizontal, 4)

            VStack(spacing: 12) {
                ForEach(PayoutPolicy.allCases, id: \.self) { policy in
                    payoutPolicyOptionRow(
                        policy: policy,
                        title: policy.displayName,
                        description: policy.subtitle,
                        icon: policy.iconSystemName
                    )
                }
            }
        }
        .padding(.horizontal)
    }

    private func payoutPolicyOptionRow(policy: PayoutPolicy,
                                       title: String,
                                       description: String,
                                       icon: String) -> some View
    {
        let isSelected = selectedPolicy == policy
        return Button {
            if !isSelected {
                let previousPolicy = selectedPolicy
                selectedPolicy = policy
                actionError = nil

                Task {
                    do {
                        _ = try await familyService.updateProfilePayoutPolicy(profile: hero, policy: policy)
                    } catch {
                        selectedPolicy = previousPolicy
                        logger.error("Failed to update payout policy: \(error, privacy: .private)")
                        actionError = "Could not update payout policy. Please try again."
                    }
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: icon)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        Text(title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.primary)
                    }

                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .background(cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}
