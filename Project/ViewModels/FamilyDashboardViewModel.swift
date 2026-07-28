//
//  FamilyDashboardViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import Observation
import os

@MainActor
@Observable
final class FamilyDashboardViewModel {
    private(set) var heroes: [ProfileCache] = []

    private(set) var parents: [ProfileCache] = []

    private(set) var weekSummary: WeekendSummary?

    private(set) var pastPayouts: [AllowancePeriodCache] = []

    private(set) var isLoading: Bool = false

    private(set) var isLoadingPayouts: Bool = false

    var loadError: String?

    private let questService: QuestService
    private let treasury: TreasuryService
    private let achievements: AchievementService
    private let familyService: FamilyProfileFetching
    private let appState: AppState
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "FamilyDashboard")

    private var syncSubscriptionID: UUID?
    private var syncTask: Task<Void, Never>?
    private var syncRefreshTask: Task<Void, Never>?

    init(questService: QuestService,
         treasury: TreasuryService,
         achievementService: AchievementService,
         familyService: FamilyProfileFetching,
         appState: AppState)
    {
        self.questService = questService
        self.treasury = treasury
        achievements = achievementService
        self.familyService = familyService
        self.appState = appState
    }

    func refresh() async {
        guard let family = appState.family else {
            heroes = []
            parents = []
            weekSummary = nil
            return
        }

        isLoading = true
        defer { isLoading = false }

        let cloudKit = questService.cloudKitReference
        if appState.isZoneOwner, appState.activeShareURL == nil, let zoneID = appState.familyZoneID {
            appState.activeShareURL = try? await cloudKit.fetchOrCreateShareURL(in: zoneID, rootRecordID: family.id)
        }
    }

    func rebuildLists(
        profiles: [ProfileCache],
        quests: [QuestCache],
        logs: [QuestCompletionCache],
        ledgers: [LedgerEntryCache],
        allowancePeriods: [AllowancePeriodCache],
        profileAchievements: [ProfileAchievementCache],
        achievements _: [AchievementCache]
    ) {
        let weekOf = WeekMath.weekOf(date: Date())
        let monday = WeekMath.mondayOfWeek(for: weekOf)
        let weekRange = WeekMath.weekRange(starting: monday)
        let questByName = Dictionary(
            quests.map { ($0.recordName, $0) },
            uniquingKeysWith: { current, _ in current }
        )

        let active = profiles.filter(\.isActive)
        heroes = active
            .filter { $0.roleEnum == .hero }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        parents = active
            .filter(\.roleEnum.isParent)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        var heroSummaries: [HeroSummary] = []
        heroSummaries.reserveCapacity(heroes.count)

        for hero in heroes {
            let heroQuests = quests.filter { $0.assigneeRecordName == hero.recordName && $0.weekOf == weekOf }
            let heroLogs = logs.filter { $0.completerRecordName == hero.recordName && $0.weekOf == weekOf }
            let completed = heroLogs.filter {
                $0.verificationStatus == VerificationStatus.autoApproved.rawValue || $0.verificationStatus == VerificationStatus.verified.rawValue
            }

            let weekLogs = logs.filter {
                $0.completerRecordName == hero.recordName && weekRange.contains($0.weekOf)
            }
            let slainLogs = weekLogs.filter {
                $0.verificationStatus == VerificationStatus.verified.rawValue
                    || $0.verificationStatus == VerificationStatus.autoApproved.rawValue
            }
            var goldFromQuests = slainLogs.reduce(into: 0.0) { acc, log in
                if let quest = questByName[log.questRecordName] {
                    acc += quest.goldReward
                }
            }
            let assignedQuests = quests.filter {
                $0.assigneeRecordName == hero.recordName && weekRange.contains($0.weekOf)
            }
            if hero.payoutPolicyEnum == .allOrNothing,
               !assignedQuests.isEmpty,
               slainLogs.count < assignedQuests.count
            {
                goldFromQuests = 0
            }

            let heroLedgers = ledgers.filter {
                $0.profileRecordName == hero.recordName && weekRange.contains($0.date)
            }
            let bonusGold = heroLedgers
                .filter { $0.amount > 0 }
                .reduce(0.0) { $0 + $1.amount }
            let earned = goldFromQuests + bonusGold

            // derive `streak` and `trophiesEarned` synchronously from the
            // cache arrays passed into `rebuildLists` (NO CloudKit fetch). The
            // prior implementation reused the stale `weekSummary` from the
            // previous render (itself built from `existing ?? 0`), so the
            // recurrence bottomed out at 0/0 on a fresh launch and never
            // advanced — a correctness regression.
            let streakLogs = logs.filter { $0.completerRecordName == hero.recordName }
            let streak = HeroDashboardViewModel.computeStreak(from: streakLogs)
            let trophies = profileAchievements
                .filter { $0.profileRecordName == hero.recordName }
                .count

            heroSummaries.append(HeroSummary(
                profile: hero,
                weeklyQuestsCompleted: completed.count,
                weeklyQuestsTotal: heroQuests.count,
                weeklyGoldEarned: earned,
                currentStreak: streak,
                trophiesEarned: trophies
            ))
        }

        let totalEarned = heroSummaries.reduce(into: 0.0) { $0 += $1.weeklyGoldEarned }
        let totalQuests = heroSummaries.reduce(into: 0) { $0 += $1.weeklyQuestsCompleted }
        weekSummary = WeekendSummary(
            weekOf: TreasuryService.mondayOfWeek(for: weekOf),
            totalEarned: totalEarned,
            totalQuestsCompleted: totalQuests,
            heroSummaries: heroSummaries
        )

        // `pastPayouts` is a computed property of the `@Query
        // cachedAllowancePeriods` passed in by `FamilyDashboardView` (replaces
        // the deleted `loadPastPayouts()` cache-fetch path). A silent push
        // that mutates an `AllowancePeriodCache` row re-fires
        // `.onChange(of: cachedAllowancePeriods)` → `rebuild()` → here, with
        // NO CloudKit fetch. Sorted by `weekOf` descending (most recent first)
        // and scoped to the current family.
        let familyName = appState.family?.id.recordName
        pastPayouts = allowancePeriods
            .filter { familyName == nil || $0.familyRecordName == familyName }
            .sorted { $0.weekOf > $1.weekOf }

        if loadError != nil {
            loadError = nil
        }
    }

    var isGuildMaster: Bool {
        appState.currentProfile?.role == .guildMaster
    }

    func subscribeToSyncEvents(_ coordinator: AppSyncCoordinator) {
        guard syncSubscriptionID == nil else { return }
        let (stream, id) = coordinator.subscribe()
        syncSubscriptionID = id
        syncTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .recordChanged:
                    handleRecordChangedSync()
                case .shareAccepted, .zoneReset:
                    await refresh()
                }
            }
        }
    }

    private func handleRecordChangedSync() {
        // the cache + `.onChange` already refresh the dashboard on
        // `.recordChanged`. The display-name-stale heuristic and the
        // `scheduleLatePropagationRetry` 1.5s retry loop were removed (they
        // fired on every silent push and only papered over a stale-CK-read
        // race). A single background `fetchAllProfilesForFamily` refreshes
        // SwiftData for any data not yet in cache; the resulting mutation
        // re-fires `.onChange` → `rebuildLists`. NO retry loop.
        //
        // Debounce: rapid `.recordChanged` bursts cancel the sleeping task
        // before it reaches the fetch, so at most ONE fetch fires per burst.
        syncRefreshTask?.cancel()
        guard let family = appState.family else { return }
        syncRefreshTask = Task { [familyService] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            _ = try? await familyService.fetchAllProfilesForFamily(family)
        }
    }

    func unsubscribeFromSyncEvents(_ coordinator: AppSyncCoordinator) {
        syncRefreshTask?.cancel()
        syncRefreshTask = nil
        syncTask?.cancel()
        syncTask = nil
        if let id = syncSubscriptionID {
            coordinator.unsubscribe(id: id)
            syncSubscriptionID = nil
        }
    }

    func reset() {
        heroes = []
        parents = []
        weekSummary = nil
        pastPayouts = []
        loadError = nil
        isLoading = false
        isLoadingPayouts = false
        syncRefreshTask?.cancel()
        syncRefreshTask = nil
    }
}

struct WeekendSummary: Equatable {
    let weekOf: Date

    let totalEarned: Double

    let totalQuestsCompleted: Int

    let heroSummaries: [HeroSummary]
}

extension WeekendSummary {
    var totalQuestsAssigned: Int {
        heroSummaries.reduce(into: 0) { $0 += $1.weeklyQuestsTotal }
    }
}

struct HeroSummary: Equatable, Identifiable {
    var id: String {
        profile.recordName
    }

    let profile: ProfileCache

    let weeklyQuestsCompleted: Int

    let weeklyQuestsTotal: Int

    let weeklyGoldEarned: Double

    let currentStreak: Int

    let trophiesEarned: Int

    var avatarRenderSpec: AvatarRenderSpec?
}
