//
//  HeroSettingsView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import os
import SwiftUI

struct HeroSettingsView: View {
    let hero: ProfileCache

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "HeroSettings")

    @Environment(ToastManager.self) private var toastManager
    @Environment(AppState.self) private var appState
    @Environment(FamilyService.self) private var familyService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var selectedPolicy: PayoutPolicy?
    @State private var selectedDayOverride: PayoutDay?
    @State private var actionError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var saveDayTask: Task<Void, Never>?

    init(hero: ProfileCache) {
        self.hero = hero
        _selectedPolicy = State(initialValue: hero.payoutPolicyEnum)
        _selectedDayOverride = State(initialValue: hero.payoutDayEnum)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Hero Header Card
                    heroHeaderCard

                    // Savings & Bucket Allocations
                    savingsAllocationsSection

                    // Payout Day Override
                    payoutDayOverrideSection

                    // Payout Policy Section with Radio Cards
                    payoutPolicySection
                }
                .padding(.vertical, 16)
            }
            .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
            .navigationTitle("\(hero.displayName)'s Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onChange(of: hero.payoutPolicyEnum) { _, newPolicy in
                selectedPolicy = newPolicy
            }
            .onChange(of: hero.payoutDayEnum) { _, newDay in
                selectedDayOverride = newDay
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
                    // Level pill and class name stay unrendered while the
                    // immersive layer is off; the sanctioned role label takes
                    // their place.
                    Text(hero.roleEnum?.displayName ?? "Hero")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                }
            }

            Spacer()
        }
        .padding(16)
        .background(cardBackground)
        .padding(.horizontal)
    }

    private var avatarView: some View {
        ProfileAvatarView(profileCache: hero)
    }

    // MARK: - Savings Allocations Section

    private var savingsAllocationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Savings Allocations")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Spend Bucket", systemImage: "cart.fill")
                        .font(.subheadline)
                    Spacer()
                    Text("\(hero.splitPercentSpend)%")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                Divider()
                HStack {
                    Label("Short-Term Goal", systemImage: "target")
                        .font(.subheadline)
                    Spacer()
                    Text("\(hero.splitPercentShort)%")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                Divider()
                HStack {
                    Label("Long-Term Treasury", systemImage: "lock.shield.fill")
                        .font(.subheadline)
                    Spacer()
                    Text("\(hero.splitPercentLong)%")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }

                if hero.interestEnabled || hero.matchEnabled {
                    Divider()
                    if hero.interestEnabled {
                        HStack {
                            Label("Interest Rate", systemImage: "chart.line.uptrend.xyaxis")
                                .font(.subheadline)
                                .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                            Spacer()
                            Text("\(Double(hero.interestRateBps) / 100.0, specifier: "%g")%")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                        }
                    }
                    if hero.matchEnabled {
                        HStack {
                            Label("Match Rate", systemImage: "arrow.trianglehead.branch")
                                .font(.subheadline)
                                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                            Spacer()
                            Text("\(Double(hero.matchRateBps) / 100.0, specifier: "%g")%")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                        }
                    }
                }
            }
            .padding(14)
            .background(cardBackground)
            .padding(.horizontal)
        }
    }

    // MARK: - Payout Day Override Section

    private var payoutDayOverrideSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Weekly Payout Day")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)

            HStack {
                Label("Hero Payout Day", systemImage: "calendar.badge.clock")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Payout Day", selection: Binding(
                    get: { selectedDayOverride },
                    set: { newDay in
                        saveDayTask?.cancel()
                        let previous = selectedDayOverride
                        withAnimation(accessibilityReduceMotion ? .none : .snappy(duration: 0.2, extraBounce: 0)) {
                            selectedDayOverride = newDay
                        }
                        actionError = nil
                        saveDayTask = Task {
                            do {
                                try await Task.sleep(nanoseconds: 350_000_000)
                                try Task.checkCancellation()
                                _ = try await familyService.updateProfilePayoutDay(profileCache: hero, day: newDay)
                            } catch {
                                guard !Task.isCancelled else { return }
                                withAnimation(accessibilityReduceMotion ? .none : .snappy(duration: 0.2, extraBounce: 0)) {
                                    selectedDayOverride = previous
                                }
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
            .padding(.horizontal)
        }
    }

    // MARK: - Payout Policy Radio Section

    private var payoutPolicySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Allowance Payout Rule")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)

            VStack(spacing: 12) {
                payoutPolicyOptionRow(
                    policy: nil,
                    title: "Use Default for Guild",
                    description: "Inherits the Guild default rule.",
                    icon: "building.columns.fill"
                )

                ForEach(PayoutPolicy.allCases, id: \.self) { policy in
                    payoutPolicyOptionRow(
                        policy: policy,
                        title: policy.displayName,
                        description: policy.subtitle,
                        icon: policy.iconSystemName
                    )
                }
            }
            .padding(.horizontal)
        }
    }

    private func payoutPolicyOptionRow(policy: PayoutPolicy?,
                                       title: String,
                                       description: String,
                                       icon: String) -> some View
    {
        let isSelected = selectedPolicy == policy
        return Button {
            if !isSelected {
                saveTask?.cancel()
                let previousPolicy = selectedPolicy
                withAnimation(accessibilityReduceMotion ? .none : .snappy(duration: 0.2, extraBounce: 0)) {
                    selectedPolicy = policy
                }
                actionError = nil

                saveTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: 350_000_000)
                        try Task.checkCancellation()
                        _ = try await familyService.updateProfilePayoutPolicy(profileCache: hero, policy: policy)
                    } catch {
                        guard !Task.isCancelled else { return }
                        withAnimation(accessibilityReduceMotion ? .none : .snappy(duration: 0.2, extraBounce: 0)) {
                            selectedPolicy = previousPolicy
                        }
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(description)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(DesignSystemConstants.Colors.cardSurface))
    }
}
