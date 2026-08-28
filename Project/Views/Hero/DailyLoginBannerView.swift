//
//  DailyLoginBannerView.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import os
import SwiftUI

struct DailyLoginBannerView: View {
    @Environment(DailyLoginService.self) private var dailyLoginService
    @Environment(GemService.self) private var gemService
    @Environment(SoundManager.self) private var soundManager
    @Environment(CelebrationManager.self) private var celebrationManager
    @Environment(AppState.self) private var appState

    /// Renders a compact one-line pill once today's reward is claimed.
    let compactMode: Bool

    @State private var isPulsing = false
    @State private var isClaiming = false

    init(compactMode: Bool = true) {
        self.compactMode = compactMode
    }

    private var status: DailyLoginStatus {
        dailyLoginService.checkDailyLoginStatus(heroProfileRecordName: appState.currentProfile?.id.recordName ?? "")
    }

    private var shouldRenderCompactPill: Bool {
        compactMode && status == .claimedToday
    }

    var body: some View {
        // Legacy RPG chrome hidden when FeatureFlags.rpgImmersive is false.
        Group {
            if !FeatureFlags.rpgImmersive {
                EmptyView()
            } else if shouldRenderCompactPill {
                compactPill
            } else {
                fullBanner
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }

    private var compactPill: some View {
        HStack(spacing: DesignSystemConstants.Padding.small) {
            Image(systemName: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
            Text("Daily Reward — claimed")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystemConstants.Padding.small)
        .padding(.horizontal, DesignSystemConstants.Padding.standard)
        .background(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.85))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Daily Reward claimed")
    }

    private var fullBanner: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.medium) {
            Text("🎁 Daily Adventurer Reward")
                .font(.headline)
                .foregroundColor(.primary)

            HStack(spacing: DesignSystemConstants.Padding.small) {
                ForEach(1 ... dailyLoginService.maxCycleDay, id: \.self) { day in
                    dayIndicator(for: day)
                }
            }

            Button {
                Task {
                    await claimReward()
                }
            } label: {
                Text(status == .claimedToday ? "Claimed Today ✓" : "Claim Reward")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystemConstants.Padding.medium)
                    .background(status == .claimedToday ? Color.secondary : Color(DesignSystemConstants.Colors.pendingAmber))
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.button))
            }
            .disabled(status == .claimedToday || isClaiming)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(status == .claimedToday ? "Reward Claimed Today" : "Claim Daily Reward")
        }
        .padding(DesignSystemConstants.Padding.standard)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card))
    }

    private func dayState(for day: Int) -> (isClaimed: Bool, isCurrent: Bool) {
        let currentCycleDay = dailyLoginService.currentCycleDay
        let status = dailyLoginService.checkDailyLoginStatus(heroProfileRecordName: appState.currentProfile?.id.recordName ?? "")
        let isClaimedToday = (status == .claimedToday)

        if isClaimedToday {
            if currentCycleDay == 1 {
                return (true, false)
            } else {
                return (day < currentCycleDay, false)
            }
        } else {
            return (day < currentCycleDay, day == currentCycleDay)
        }
    }

    @ViewBuilder
    private func dayIndicator(for day: Int) -> some View {
        let state = dayState(for: day)
        let isClaimed = state.isClaimed
        let isCurrent = state.isCurrent

        VStack {
            ZStack {
                Circle()
                    .fill(isClaimed ? Color(DesignSystemConstants.Colors.primaryGreen) :
                        (isCurrent ? Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.2) : Color.secondary.opacity(0.2)))
                    .frame(width: 36, height: 36)

                if isClaimed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text("\(dailyLoginService.rewards[day] ?? 5)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(isCurrent ? Color(DesignSystemConstants.Colors.pendingAmber) : .secondary)
                }
            }
            .overlay(
                Circle()
                    .stroke(isCurrent ? Color(DesignSystemConstants.Colors.pendingAmber) : Color.clear, lineWidth: isCurrent ? (isPulsing ? 3 : 1) : 0)
                    .scaleEffect(isCurrent && isPulsing ? 1.1 : 1.0)
            )

            Text("Day \(day)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Day \(day)")
        .accessibilityValue(isClaimed ? "Claimed" : (isCurrent ? "Current day, \(dailyLoginService.rewards[day] ?? 5) gems" : "\(dailyLoginService.rewards[day] ?? 5) gems"))
    }

    private func claimReward() async {
        guard let profile = appState.currentProfile else { return }
        isClaiming = true
        do {
            let gems = try await dailyLoginService.claimDailyReward(for: profile, gemService: gemService, soundManager: soundManager)
            if gems > 0 {
                celebrationManager.enqueueDailyLogin(heroName: profile.displayName, gems: gems, streakDays: dailyLoginService.currentStreakDays)
            }
        } catch {
            Logger(subsystem: "com.volcrypt.lootlist", category: "DailyLoginBanner").error("Failed to claim daily reward: \(error)")
        }
        isClaiming = false
    }
}
