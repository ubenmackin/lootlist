//
//  CelebrationManager.swift
//  LootList
//
//  Created by Ben Mackin on 8/10/26.
//

import Foundation
import SwiftUI

/// A single trophy or streak-milestone celebration queued for presentation.
/// Built directly from an `Achievement`'s existing fields — no new CloudKit
/// model is required.
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
    /// Convenience initializer that maps an `Achievement` onto the celebration
    /// payload without introducing a new persisted type.
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

    /// `true` when the item celebrates a streak milestone (7 or 30 consecutive
    /// days). Used to distinguish combo-streak celebrations from regular trophy
    /// unlocks in the overlay copy and enhanced-toast prefix.
    var isStreakMilestone: Bool {
        switch requirementType {
        case .streak7, .streak30: true
        default: false
        }
    }
}

/// Global celebration presenter. Observable, main-actor isolated, injected via
/// `@Environment` from `LootListApp` — mirroring the existing `ToastManager`
/// injection pattern. The first queued item triggers the fullscreen overlay;
/// items arriving while the fullscreen is on screen are held in the queue and
/// surfaced as enhanced toasts immediately after the fullscreen dismisses.
@MainActor
@Observable
final class CelebrationManager {
    /// Items waiting to be celebrated. The head of the queue is the
    /// currently-presented fullscreen item while `isPresentingFullscreen` is
    /// `true`.
    private(set) var queue: [CelebrationItem] = []

    /// `true` while the fullscreen celebration overlay is on screen.
    private(set) var isPresentingFullscreen: Bool = false

    /// Toast surface used to drain queued items as enhanced toasts after the
    /// fullscreen overlay dismisses. Injected from `LootListApp`.
    var toastManager: ToastManager?

    /// Auto-dismiss delay for the fullscreen overlay.
    private static let fullscreenAutoDismissSeconds: UInt64 = AppConstants.UserInterface.celebrationAutoDismissSeconds

    /// Active auto-dismiss task for the fullscreen overlay, cancelled on
    /// manual skip.
    private var autoDismissTask: Task<Void, Never>?

    init() {}

    /// The fullscreen overlay binds to this; it is the head of the queue while
    /// a fullscreen presentation is active, and `nil` otherwise.
    var currentFullscreenItem: CelebrationItem? {
        isPresentingFullscreen ? queue.first : nil
    }

    /// Enqueues newly awarded achievements for celebration. Called by
    /// `AchievementService.evaluateAll` after awards and streak-milestone
    /// notifications have fired. The `for:` profile parameter is accepted to
    /// match the service-layer call shape; the celebration payload is derived
    /// solely from the achievement fields.
    func enqueue(achievements: [Achievement], for _: Profile? = nil) {
        guard !achievements.isEmpty else { return }
        let items = achievements.map { CelebrationItem(achievement: $0) }
        queue.append(contentsOf: items)
        presentNextIfIdle()
    }

    func enqueueLevelUp(oldLevel: Int, newLevel: Int, heroName: String) {
        let item = CelebrationItem(oldLevel: oldLevel, newLevel: newLevel, heroName: heroName)
        queue.append(item)
        presentNextIfIdle()
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
        queue.append(item)
        presentNextIfIdle()
    }

    /// Dismisses the current fullscreen celebration and drains any remaining
    /// queued items as enhanced toasts. Safe to call multiple times — the
    /// fullscreen state and queue are guarded so a manual tap-to-skip racing
    /// the auto-dismiss timer cannot crash on an empty queue.
    func dismissCurrent() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        guard isPresentingFullscreen || !queue.isEmpty else { return }
        if !queue.isEmpty {
            _ = queue.removeFirst()
        }
        isPresentingFullscreen = false

        // Items that arrived during the fullscreen presentation are surfaced
        // as enhanced toasts rather than stacking another fullscreen overlay.
        let remaining = queue
        queue.removeAll()
        for item in remaining {
            showEnhancedToast(for: item)
        }
    }

    /// Presents the head of the queue as a fullscreen overlay only when no
    /// fullscreen is already active; otherwise the item waits in the queue.
    private func presentNextIfIdle() {
        guard !isPresentingFullscreen, !queue.isEmpty else { return }
        isPresentingFullscreen = true
        scheduleAutoDismiss()
    }

    /// Schedules a non-blocking auto-dismiss. The sleep runs off the main
    /// thread and hops back to MainActor only to dismiss the fullscreen.
    private func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.fullscreenAutoDismissSeconds))
            if !Task.isCancelled {
                self?.dismissCurrent()
            }
        }
    }

    /// Surfaces a queued item as an enhanced success toast once the fullscreen
    /// overlay has dismissed.
    private func showEnhancedToast(for item: CelebrationItem) {
        let prefix: String = if item.isLevelUp {
            "⬆️ Level Up!"
        } else {
            item.isStreakMilestone ? "🔥 Streak Milestone!" : "🏆 Trophy Unlocked!"
        }
        toastManager?.show(message: "\(prefix) \(item.name)", type: .success)
    }
}
