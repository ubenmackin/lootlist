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

    init(id: UUID = UUID(),
         name: String,
         description: String,
         iconSystemName: String,
         category: AchievementCategory,
         requirementType: AchievementRequirement,
         requirementValue: Int)
    {
        self.id = id
        self.name = name
        self.description = description
        self.iconSystemName = iconSystemName
        self.category = category
        self.requirementType = requirementType
        self.requirementValue = requirementValue
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
    private static let fullscreenAutoDismissSeconds: UInt64 = 6

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

    /// Dismisses the current fullscreen celebration and drains any remaining
    /// queued items as enhanced toasts. Safe to call multiple times — the
    /// fullscreen state and queue are guarded so a manual tap-to-skip racing
    /// the auto-dismiss timer cannot crash on an empty queue.
    func dismissCurrent() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        if !queue.isEmpty {
            queue.removeFirst()
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
        let prefix = item.isStreakMilestone ? "🔥 Streak Milestone!" : "🏆 Trophy Unlocked!"
        toastManager?.show(message: "\(prefix) \(item.name)", type: .success)
    }
}
