//
//  AutoPayoutCoordinator.swift
//  LootList
//
//  Created by Ben Mackin on 8/9/26.
//

import CloudKit
import Foundation
import os

@MainActor
final class AutoPayoutCoordinator {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "AutoPayoutCoordinator")

    private let treasuryService: TreasuryService
    private let questService: QuestService
    private let familyService: FamilyService
    private let appState: AppState

    private var isProcessing = false

    init(
        treasuryService: TreasuryService,
        questService: QuestService,
        familyService: FamilyService,
        appState: AppState
    ) {
        self.treasuryService = treasuryService
        self.questService = questService
        self.familyService = familyService
        self.appState = appState
    }

    /// Evaluates whether payouts or quest sweeps are due for any hero in the active family
    /// and executes them atomically. Safe to call on cold launch, scene foreground, or background refresh.
    @discardableResult
    func processPendingPayoutsIfDue(now: Date = Date()) async -> Int {
        guard !isProcessing else {
            logger.debug("Auto-payout evaluation already in progress. Skipping.")
            return 0
        }

        guard let currentProfile = appState.currentProfile,
              currentProfile.role.isParent,
              let family = appState.family
        else {
            logger.debug("Active profile is not a parent or family missing. Skipping auto-payout.")
            return 0
        }

        isProcessing = true
        defer { isProcessing = false }

        var processedCount = 0

        do {
            let heroes = try await familyService.fetchHeroes(for: family)

            for hero in heroes {
                // Real-time heroes have no weekly payout step — their earnings are
                // settled via runPayout's real-time guard on each quest completion.
                // Skip them here to avoid creating a no-op allowance period and
                // emitting misleading logs.
                guard hero.payoutPolicy != .realTime else { continue }

                let payoutDay = hero.payoutDay ?? family.payoutDay
                let currentWeekStart = WeekMath.startOfWeek(for: now, payoutDay: payoutDay)

                // Check current week and previous week for open allowance periods
                let candidateWeeks = [
                    currentWeekStart,
                    Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: currentWeekStart) ?? currentWeekStart
                ]

                for weekOf in candidateWeeks {
                    // Check if today has reached or passed the payout day for this week
                    let payoutDate = Calendar.iso8601UTC.date(byAdding: .day, value: 6, to: weekOf) ?? weekOf
                    guard now >= Calendar.iso8601UTC.startOfDay(for: payoutDate) else {
                        continue
                    }

                    do {
                        let period = try await treasuryService.getOrCreateAllowancePeriod(
                            profile: hero,
                            weekOf: weekOf,
                            family: family
                        )

                        // Atomic double-run prevention lock: skip if already paid
                        guard period.status != .paid else {
                            continue
                        }

                        logger.info("Executing auto-payout for hero \(hero.displayName) for week \(weekOf)")
                        try await treasuryService.runPayout(period: period)
                        processedCount += 1
                    } catch {
                        logger.error("Error processing auto-payout for hero \(hero.displayName): \(error, privacy: .public)")
                    }
                }
            }

            // Retire quests from past weeks whose payouts have been finalized. The sweep
            // excludes the current week, so an early payout never deactivates this
            // week's still-active quests; they retire on the next week rollover.
            let familyWeekStart = WeekMath.startOfWeek(for: now, payoutDay: family.payoutDay)
            let sweptQuests = try await questService.sweepExpiredQuests(family: family, currentWeekOf: familyWeekStart)
            if !sweptQuests.isEmpty {
                logger.info("Swept \(sweptQuests.count) expired quests for family \(family.name)")
            }
        } catch {
            logger.error("Failed during auto-payout evaluation: \(error, privacy: .public)")
        }

        return processedCount
    }
}
