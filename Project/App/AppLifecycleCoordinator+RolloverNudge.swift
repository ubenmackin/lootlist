//
//  AppLifecycleCoordinator+RolloverNudge.swift
//  LootList
//
//  Created by Ben Mackin on 9/26/26.
//

import Foundation

@MainActor
extension AppLifecycleCoordinator {
    /// WHY parent-only: heroes never own payout settlement, so only parents keep the weekly nudge.
    func scheduleRolloverNudgeIfParent(now: Date = Date()) async {
        guard let appState,
              let profile = appState.currentProfile,
              let family = appState.family,
              profile.role.isParent
        else {
            cancelRolloverNudge()
            return
        }
        await RolloverNudgeScheduler.scheduleWeeklyRolloverNudge(payoutDay: family.payoutDay, now: now)
    }

    /// WHY sync cancel: role changes and session clears must not leave a stale parent nudge behind.
    func cancelRolloverNudge() {
        RolloverNudgeScheduler.cancelRolloverNudge()
    }
}
