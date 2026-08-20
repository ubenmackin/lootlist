//
//  AutoPayoutCoordinator.swift
//  LootList
//
//  Created by Ben Mackin on 8/9/26.
//

import CloudKit
import Foundation
import os
import Synchronization

@MainActor
final class AutoPayoutCoordinator {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "AutoPayoutCoordinator")

    private let treasuryService: TreasuryService
    private let questService: QuestService
    private let familyService: FamilyService
    private let appState: AppState

    /// Shared in-app toast surface. Mirrors the `toastManager` injection on
    /// `AchievementService`/`QuestService`/`TreasuryService`. Optional so the
    /// coordinator can be constructed without it (read-only test paths); when
    /// present, a summary banner is emitted after a weekly carry-forward pass.
    let toastManager: ToastManager?

    /// Atomic double-run guard. See `processPendingPayoutsIfDue` — a plain Bool on
    /// `@MainActor` races when two callers (scenePhase .active + BGAppRefreshTask)
    /// invoke concurrently: the second can read `false` before the first sets `true`
    /// across the first `await` gap (fetchHeroes). `Mutex<Bool>` makes check-and-set
    /// synchronous via `withLock` before any suspension point.
    private let isProcessing = Mutex<Bool>(false)

    init(
        treasuryService: TreasuryService,
        questService: QuestService,
        familyService: FamilyService,
        appState: AppState,
        toastManager: ToastManager? = nil
    ) {
        self.treasuryService = treasuryService
        self.questService = questService
        self.familyService = familyService
        self.appState = appState
        self.toastManager = toastManager
    }

    // MARK: - Payout Evaluation

    /// Evaluates whether payouts or quest sweeps are due for any hero in the active family
    /// and executes them atomically. Safe to call on cold launch, scene foreground, or background refresh.
    @discardableResult
    func processPendingPayoutsIfDue(now: Date = Date()) async -> Int {
        guard let currentProfile = appState.currentProfile,
              currentProfile.role.isParent,
              let family = appState.family
        else {
            logger.debug("Active profile is not a parent or family missing. Skipping auto-payout.")
            return 0
        }

        // Atomic check-and-set via Mutex so concurrent callers (scenePhase .active
        // + BGAppRefreshTask) cannot both enter the heroes loop. The withLock
        // section is synchronous and completes before the first await (fetchHeroes),
        // closing the await-gap race where a plain Bool on @MainActor would still
        // read false after the first caller yielded. Reproduce: concurrent
        // Task { await coordinator.processPendingPayoutsIfDue(now:) } x2 with same
        // now where payout is due — processedCount must be 1, not 2.
        guard isProcessing.withLock({ flag in
            guard !flag else { return false }
            flag = true
            return true
        }) else {
            logger.debug("Auto-payout evaluation already in progress. Skipping.")
            return 0
        }
        defer { isProcessing.withLock { $0 = false } }

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
                    Calendar.iso8601UTC.date(byAdding: .day, value: AppConstants.Economy.previousWeekDayOffset, to: currentWeekStart) ?? currentWeekStart
                ]

                for weekOf in candidateWeeks {
                    // Half-open payout gate: the week owns [weekOf, weekOf+7d).
                    // payoutDate is the exclusive upper bound (next Monday 00:00 UTC
                    // for the effective per-hero payout-day-anchored week) via
                    // WeekMath.weekRange(starting:).upperBound. Gating on
                    // now >= upperBound fires at the instant the week closes, not
                    // at Sunday 00:00 a full day early (prior: weekOf + 6 days then
                    // startOfDay(payoutDate)). Reusing the canonical half-open
                    // range also avoids DST 23h/25h midnight drift — UTC has no
                    // DST, but the +6d + startOfDay path double-normalizes and
                    // could fire early on spring-forward 23h days if the calendar
                    // were ever non-UTC. Documented choice: strict >= upperBound
                    // (end-of-day Sunday Loot Day) keeps the range half-open and
                    // consistent with WeekMath/TreasuryService/QuestService; callers
                    // needing inclusive end-of-day should use upperBound - 1 second
                    // with a calendar-aware check explicitly.
                    let payoutDate = WeekMath.weekRange(starting: weekOf).upperBound
                    guard now >= payoutDate else {
                        continue
                    }

                    do {
                        let period = try await treasuryService.getOrCreateAllowancePeriod(
                            profile: hero,
                            weekOf: weekOf,
                            family: family
                        )

                        // Local status pre-check backed by save-layer CAS on AllowancePeriod: skip if already paid
                        guard period.status != .paid else {
                            continue
                        }

                        logger.info("Executing auto-payout for hero \(hero.displayName, privacy: .private) for week \(weekOf, privacy: .private)")
                        try await treasuryService.runPayout(period: period)
                        processedCount += 1
                    } catch {
                        logger.error("Error processing auto-payout for hero \(hero.displayName, privacy: .private): \(error, privacy: .private)")
                    }
                }
            }

            // Retire quests from past weeks whose payouts have been finalized. The sweep
            // excludes the current week, so an early payout never deactivates this
            // week's still-active quests; they retire on the next week rollover.
            let familyWeekStart = WeekMath.startOfWeek(for: now, payoutDay: family.payoutDay)
            let sweptQuests = try await questService.sweepExpiredQuests(family: family, currentWeekOf: familyWeekStart)
            if !sweptQuests.isEmpty {
                logger.info("Swept \(sweptQuests.count) expired quests for family \(family.name, privacy: .private)")
            }

            // Recurring quest carry-forward: roll template-backed quests from
            // the previous week into the current week so a parent doesn't have
            // to reassign recurring chores each week. Parent-only by virtue of
            // the role guard above; idempotent so re-runs in the same week don't
            // duplicate assignments.
            await carryForwardRecurringQuests(
                family: family,
                heroes: heroes,
                currentProfile: currentProfile,
                now: now
            )
        } catch {
            logger.error("Failed during auto-payout evaluation: \(error, privacy: .private)")
        }

        return processedCount
    }

    /// Carries forward recurring template-backed quests from the previous week
    /// into the current week.
    ///
    /// For each unique `(template, assignee)` tuple that existed in the previous
    /// week, a new quest is assigned for the current week — unless one for that
    /// tuple already exists (idempotent). A pair whose current-week quest was
    /// explicitly unassigned by a parent mid-week is protected by a suppression
    /// tombstone (see ``QuestService.unassignQuest``): the unassigned row is
    /// retained with `active == false`, so the pair stays occupied in the
    /// idempotency gate for the current carry window and is never re-created
    /// until the week rolls over. Quests backed by an inactive template
    /// (ad-hoc Quick Create quests carry `isActive == false` templates), by a
    /// template that has since been deleted, or assigned to a profile no longer
    /// on the family roster are skipped. All template defaults (schedule type,
    /// target count, specific days) are preserved by passing `nil` overrides to
    /// ``QuestService.assignQuest``.
    ///
    /// **Per-assignee payout-day anchoring.** `assignQuest` stores `weekOf`
    /// normalized to the assignee's effective payout day (profile override →
    /// family payout day → `.sunday` fallback), so the source window, the
    /// idempotency gate, and the `weekOf` value handed to ``assignQuest`` must
    /// all use the same per-assignee anchor. A hero with a per-profile
    /// override (e.g. a `.friday` hero in a `.sunday` family) has a week
    /// shifted by up to six days from the family cycle; anchoring everything
    /// on the family payday instead would land the stored current-week row
    /// outside the engine's own gate (duplicate assignments on every run) AND
    /// hide the unassign tombstone (which is keyed on the same assignee-anchored
    /// `weekOf`) from the gate. Heroes sharing an effective payout day share
    /// one fetch pair; override heroes get their own.
    private func carryForwardRecurringQuests(
        family: Family,
        heroes: [Profile],
        currentProfile: Profile,
        now: Date
    ) async {
        guard let cache = appState.cacheService else {
            logger.debug("Cache unavailable; skipping weekly quest carry-forward.")
            return
        }

        let familyName = family.id.recordName

        // Active templates only — ad-hoc Quick Create quests back inactive
        // templates and must not recur; templates deleted between weeks are
        // absent from this set and therefore skipped.
        let activeTemplates = cache.fetchQuestTemplates(family: familyName).filter(\.isActive)
        let heroByRecordName = Dictionary(heroes.map { ($0.id.recordName, $0) }, uniquingKeysWith: { first, _ in first })
        let activeTemplateByRecordName = Dictionary(activeTemplates.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })
        let activeTemplateNames = Set(activeTemplates.map(\.recordName))

        // Group heroes by their effective per-assignee current-week start so
        // heroes sharing a payout day share one (source, gate, write) tuple.
        // Heroes with no per-profile override collapse back onto the family
        // payday, so the default configuration behaves identically to the
        // pre-fix family-anchored implementation.
        let heroesByWeekStart = Dictionary(grouping: heroes) { hero in
            WeekMath.startOfWeek(for: now, payoutDay: hero.payoutDay ?? family.payoutDay)
        }

        var totalCarriedCount = 0
        var totalCarriedPerAssignee: [String: Int] = [:]

        for (currentWeekStart, weekHeroes) in heroesByWeekStart {
            // Reuse the same ISO8601-UTC shift used elsewhere in this function
            // for deriving the previous week's start. This is the group's
            // per-hero previousWeekStart, NOT familyWeekStart — using the
            // family-anchored week would bucket override heroes (e.g. Friday
            // hero in Sunday family) 6 days off and either duplicate or miss
            // carry-forward tuples. Assertion: previousWeekStart must derive
            // from currentWeekStart for this payout-day group.
            let previousWeekStart = Calendar.iso8601UTC.date(byAdding: .day, value: AppConstants.Economy.previousWeekDayOffset, to: currentWeekStart) ?? currentWeekStart
            guard previousWeekStart < currentWeekStart else {
                logger
                    .error(
                        "Carry-forward week math corrupt: previousWeekStart \(previousWeekStart, privacy: .private) >= currentWeekStart \(currentWeekStart, privacy: .private). Skipping group."
                    )
                continue
            }
            guard WeekMath.weekRange(starting: previousWeekStart).upperBound == WeekMath.weekRange(starting: previousWeekStart).lowerBound
                .addingTimeInterval(TimeInterval(AppConstants.Time.secondsInWeek))
            else {
                logger.error("Carry-forward weekRange invariant violated for previousWeekStart \(previousWeekStart, privacy: .private). Skipping group.")
                continue
            }

            let previousQuests = cache.fetchQuests(
                family: familyName,
                weekInRange: WeekMath.weekRange(starting: previousWeekStart)
            )
            guard !previousQuests.isEmpty else { continue }

            let weekHeroNames = Set(weekHeroes.map(\.id.recordName))
            let pendingTuples = pendingCarryForwardTuples(
                from: previousQuests,
                activeTemplateNames: activeTemplateNames,
                heroNames: weekHeroNames
            )
            guard !pendingTuples.isEmpty else { continue }

            // Idempotency: skip tuples that already have a quest in the
            // current week so re-runs of the coordinator never duplicate
            // assignments. The gate deliberately spans ALL current-week rows,
            // active or not: a parent's mid-week unassign of a carried-forward
            // quest leaves a suppression tombstone
            // (`QuestService.unassignQuest` retains the row with
            // `active == false`), and that tombstone occupies the pair so the
            // engine never resurrects a quest the parent explicitly removed
            // for this week. Only pairs with no current-week row at all —
            // never created this week — fall through to assignment. The gate
            // window is anchored on the same per-assignee payout day as the
            // stored `weekOf`, so the tombstone is always visible to it.
            let existingPairs = Set(
                cache.fetchQuests(family: familyName, weekInRange: WeekMath.weekRange(starting: currentWeekStart))
                    .map { TemplateAssigneePair(template: $0.templateRecordName, assignee: $0.assigneeRecordName) }
            )

            let result = await assignCarriedForwardQuests(
                pendingTuples: pendingTuples,
                existingPairs: existingPairs,
                activeTemplateByRecordName: activeTemplateByRecordName,
                heroByRecordName: heroByRecordName,
                weekOf: currentWeekStart,
                currentProfile: currentProfile,
                family: family
            )

            totalCarriedCount += result.count
            for (assignee, count) in result.perAssignee {
                totalCarriedPerAssignee[assignee, default: 0] += count
            }
        }

        guard totalCarriedCount > 0 else { return }

        logger.info("Carried forward \(totalCarriedCount) quest(s) for family \(family.name, privacy: .private)")
        toastManager?.show(message: "Carried forward \(totalCarriedCount) quest(s) for the new week.", type: .info)
        notifyCarriedForwardQuests(totalCarriedPerAssignee, heroByRecordName: heroByRecordName)
    }

    /// Groups previous-week quests into unique `(template, assignee)` tuples,
    /// skipping quests whose backing template is inactive/gone or whose
    /// assignee is no longer on the family roster.
    private func pendingCarryForwardTuples(
        from quests: [QuestCache],
        activeTemplateNames: Set<String>,
        heroNames: Set<String>
    ) -> [TemplateAssigneePair] {
        var pendingTuples: [TemplateAssigneePair] = []
        var seenTuples = Set<TemplateAssigneePair>()
        for quest in quests {
            guard activeTemplateNames.contains(quest.templateRecordName) else { continue }
            guard heroNames.contains(quest.assigneeRecordName) else { continue }
            let pair = TemplateAssigneePair(template: quest.templateRecordName, assignee: quest.assigneeRecordName)
            if seenTuples.insert(pair).inserted {
                pendingTuples.append(pair)
            }
        }
        return pendingTuples
    }

    /// Assigns each pending `(template, assignee)` tuple for the current week,
    /// preserving template defaults via `nil` overrides. Returns the count of
    /// new assignments plus a per-assignee tally for the summary notification.
    /// `weekOf` is the current week start for this group of assignees, anchored
    /// on their effective payout day (see ``carryForwardRecurringQuests``).
    private func assignCarriedForwardQuests(
        pendingTuples: [TemplateAssigneePair],
        existingPairs: Set<TemplateAssigneePair>,
        activeTemplateByRecordName: [String: QuestTemplateCache],
        heroByRecordName: [String: Profile],
        weekOf: Date,
        currentProfile: Profile,
        family: Family
    ) async -> (count: Int, perAssignee: [String: Int]) {
        var carriedCount = 0
        var carriedPerAssignee: [String: Int] = [:]
        let zoneID = family.id.zoneID
        // Guard: every carry-forward assignment must land in the family's
        // zoneID consistently. activeTemplateByRecordName lookup is keyed on
        // templateRecordName only, but the resulting template is rehydrated
        // via toQuestTemplate(zoneID: zoneID) with family.id.zoneID so the
        // minted Quest recordName/zoneID matches the family's zone. A mismatch
        // would place the quest in the wrong zone and break fetch scoping.
        guard zoneID == family.id.zoneID else {
            logger.error("Carry-forward zoneID mismatch for family \(family.name, privacy: .private). Aborting carry-forward assignments for this group.")
            return (0, [:])
        }
        guard !zoneID.zoneName.isEmpty else {
            logger.error("Carry-forward zoneID zoneName is empty for family \(family.name, privacy: .private). Aborting carry-forward assignments for this group.")
            return (0, [:])
        }

        for pair in pendingTuples {
            if existingPairs.contains(pair) {
                continue
            }
            guard let templateCache = activeTemplateByRecordName[pair.template],
                  let assignee = heroByRecordName[pair.assignee]
            else { continue }

            do {
                _ = try await questService.assignQuest(
                    template: templateCache.toQuestTemplate(zoneID: zoneID),
                    assignee: assignee,
                    goldOverride: nil,
                    xpOverride: nil,
                    approvalOverride: nil,
                    nameOverride: nil,
                    weekOf: weekOf,
                    createdBy: currentProfile,
                    family: family
                )
                carriedCount += 1
                carriedPerAssignee[pair.assignee, default: 0] += 1
            } catch {
                logger.error(
                    "Carry-forward assignment failed for template \(pair.template, privacy: .private) assignee \(pair.assignee, privacy: .private): \(error, privacy: .private)"
                )
            }
        }
        return (carriedCount, carriedPerAssignee)
    }

    /// Sends each affected assignee a summary notification (the parent gets the
    /// in-app toast instead). Fire-and-forget on detached tasks so a
    /// notification failure never blocks the carry-forward flow.
    private func notifyCarriedForwardQuests(
        _ carriedPerAssignee: [String: Int],
        heroByRecordName: [String: Profile]
    ) {
        guard let notificationService = questService.notificationService else { return }
        for (assigneeRecordName, count) in carriedPerAssignee {
            guard let hero = heroByRecordName[assigneeRecordName] else { continue }
            let title = count == 1 ? "⚔️ New Quest Assigned!" : "⚔️ New Quests Assigned!"
            let body = "You have \(count) new quest\(count == 1 ? "" : "s") carried over for the new week."
            Task { @Sendable [logger, notificationService, hero, title, body] in
                do {
                    try await notificationService.send(.questAssigned, to: hero, title: title, body: body)
                } catch {
                    logger.error("Carry-forward summary notification failed: \(error, privacy: .private)")
                }
            }
        }
    }
}

/// Unique key for a quest's `(templateRecordName, assigneeRecordName)` pair,
/// used to group previous-week quests and to detect idempotency against the
/// current week's existing quests.
private struct TemplateAssigneePair: Hashable {
    let template: String
    let assignee: String
}
