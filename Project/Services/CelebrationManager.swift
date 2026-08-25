//
//  CelebrationManager.swift
//  LootList
//
//  Created by Ben Mackin on 8/10/26.
//

import Foundation
import SwiftUI

struct CelebrationItem: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let description: String
    let iconSystemName: String
    let category: AchievementCategory
    let requirementType: AchievementRequirement
    let requirementValue: Int
    let isLevelUp: Bool
    let oldLevel: Int?
    let newLevel: Int?
    let newTitle: String?

    init(id: UUID = UUID(),
         name: String,
         description: String,
         iconSystemName: String,
         category: AchievementCategory,
         requirementType: AchievementRequirement,
         requirementValue: Int,
         isLevelUp: Bool = false,
         oldLevel: Int? = nil,
         newLevel: Int? = nil,
         newTitle: String? = nil)
    {
        self.id = id
        self.name = name
        self.description = description
        self.iconSystemName = iconSystemName
        self.category = category
        self.requirementType = requirementType
        self.requirementValue = requirementValue
        self.isLevelUp = isLevelUp
        self.oldLevel = oldLevel
        self.newLevel = newLevel
        self.newTitle = newTitle
    }
}

extension CelebrationItem {
    init(achievement: Achievement) {
        self.init(
            name: achievement.name,
            description: achievement.description,
            iconSystemName: achievement.iconSystemName,
            category: achievement.category,
            requirementType: achievement.requirementType,
            requirementValue: achievement.requirementValue
        )
    }

    init(oldLevel: Int, newLevel: Int, heroName: String) {
        self.init(
            name: "Level Up!",
            description: "\(heroName) reached Level \(newLevel)!",
            iconSystemName: "arrow.up.circle.fill",
            category: .special,
            requirementType: .firstQuest,
            requirementValue: 1,
            isLevelUp: true,
            oldLevel: oldLevel,
            newLevel: newLevel,
            newTitle: XPService.title(forLevel: newLevel)
        )
    }

    var isStreakMilestone: Bool {
        switch requirementType {
        case .streak7, .streak30: true
        default: false
        }
    }
}

@MainActor
@Observable
final class CelebrationManager {
    var toastManager: ToastManager?

    init() {}

    // MARK: - Toast presentation

    func enqueue(achievements: [Achievement], for _: Profile? = nil) {
        guard !achievements.isEmpty else { return }
        for achievement in achievements {
            let item = CelebrationItem(achievement: achievement)
            showToast(for: item)
        }
    }

    func enqueueLevelUp(oldLevel: Int, newLevel: Int, heroName: String) {
        let item = CelebrationItem(oldLevel: oldLevel, newLevel: newLevel, heroName: heroName)
        showToast(for: item)
    }

    func enqueueDailyLogin(heroName _: String, gems: Int, streakDays: Int) {
        let item = CelebrationItem(
            name: "Daily Reward",
            description: "You earned \(gems) Gems! Streak: \(streakDays) days",
            iconSystemName: "gift.fill",
            category: .special,
            requirementType: .firstQuest,
            requirementValue: 1
        )
        showToast(for: item)
    }

    private func showToast(for item: CelebrationItem) {
        let prefix: String = if item.isLevelUp {
            "⬆️ Level Up!"
        } else {
            item.isStreakMilestone ? "🔥 Streak Milestone!" : "🏆 Trophy Unlocked!"
        }
        toastManager?.show(message: "\(prefix) \(item.name)", type: .success)
    }

    // MARK: - Confetti overlay

    /// Drives the `CelebrationOverlay` canvas — observed by the
    /// `.celebrationOverlay()` modifier attached to the root view.
    var isConfettiShowing = false

    /// Cancellable auto-dismiss so rapid successive triggers extend the
    /// lifetime rather than stacking competing dismissal timers.
    private var confettiDismissTask: Task<Void, Never>?

    /// Shows the full-screen canvas confetti overlay and schedules an
    /// auto-dismiss after the configured lifetime. Redeemable from any
    /// service or view that holds the manager — goal completions, trophy
    /// unlocks, payout celebrations, quest verifications.
    func triggerConfetti() {
        confettiDismissTask?.cancel()
        isConfettiShowing = true
        confettiDismissTask = Task {
            try? await Task.sleep(for: .seconds(DesignSystemConstants.Celebration.confettiLifetime))
            guard !Task.isCancelled else { return }
            isConfettiShowing = false
        }
    }
}
