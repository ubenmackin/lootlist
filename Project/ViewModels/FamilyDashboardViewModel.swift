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
    private(set) var heroes: [Profile] = []

    private(set) var parents: [Profile] = []

    private(set) var weekSummary: WeekendSummary?

    private(set) var pastPayouts: [AllowancePeriod] = []

    private(set) var isLoading: Bool = false

    private(set) var isLoadingPayouts: Bool = false

    var loadError: String?

    private let questService: QuestService
    private let treasury: TreasuryService
    private let achievements: AchievementService
    private let familyService: FamilyService
    private let appState: AppState
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "FamilyDashboard")

    private var syncSubscriptionID: UUID?
    private var syncTask: Task<Void, Never>?
    private var syncRefreshTask: Task<Void, Never>?
    private var lastHeroDisplayNames: [String: String] = [:]

    init(questService: QuestService,
         treasury: TreasuryService,
         achievementService: AchievementService,
         familyService: FamilyService,
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

        // Cache-first: route member discovery through FamilyService so the
        // write-through ProfileCache returns immediately on rename-related
        // retries. The background refresh inside fetchAllProfilesForFamily
        // keeps the cache honest.
        let all = await (try? familyService.fetchAllProfilesForFamily(family)) ?? []
        let active = all.filter(\.isActive)
        heroes = active
            .filter { $0.role == .hero }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        parents = active
            .filter(\.role.isParent)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        let weekOf = QuestService.mondayOfWeek(for: Date())
        var heroSummaries: [HeroSummary] = []
        heroSummaries.reserveCapacity(heroes.count)

        for hero in heroes {
            let summary = await buildHeroSummary(for: hero, weekOf: weekOf)
            heroSummaries.append(summary)
        }

        let totalEarned = heroSummaries.reduce(into: 0.0) { $0 += $1.weeklyGoldEarned }
        let totalQuests = heroSummaries.reduce(into: 0) { $0 += $1.weeklyQuestsCompleted }
        weekSummary = WeekendSummary(
            weekOf: TreasuryService.mondayOfWeek(for: weekOf),
            totalEarned: totalEarned,
            totalQuestsCompleted: totalQuests,
            heroSummaries: heroSummaries
        )

        if loadError != nil {
            loadError = nil
        }

        // Snapshot displayNames for change-detection in debounced retry
        var updatedNames: [String: String] = [:]
        for hero in heroes {
            updatedNames[hero.id.recordName] = hero.displayName
        }
        lastHeroDisplayNames = updatedNames
    }

    func loadPastPayouts(includeActive: Bool = true) async {
        guard let family = appState.family else {
            pastPayouts = []
            return
        }

        isLoadingPayouts = true
        defer { isLoadingPayouts = false }

        // Cache-first: AllowancePeriodCache returns synchronously while a
        // background CloudKit refresh keeps the cache honest. Keeps the late-
        // propagation retry cheap (no async CloudKit hit per attempt).
        let all = await treasury.fetchAllowancePeriods(family: family)
        pastPayouts = includeActive
            ? all
            : all.filter { $0.status == .paid }
    }

    private func buildHeroSummary(for hero: Profile,
                                  weekOf: Date) async -> HeroSummary
    {
        async let questsTask: [Quest]? = try? questService.fetchActiveQuests(
            profile: hero, weekOf: weekOf
        )
        async let logsTask: [QuestCompletion]? = try? questService.fetchQuestLogs(
            for: hero
        )
        async let streakTask: Int? = try? questService.fetchStreak(for: hero)
        async let earnedTask: Double? = try? treasury.weeklyBreakdown(
            profile: hero, weekOf: weekOf
        ).totalEarned

        async let earnedTrophiesTask: [ProfileAchievement]? = try? achievements.fetchEarned(
            profile: hero
        )

        let quests = await questsTask ?? []
        let logs = await logsTask ?? []
        let streak = await streakTask ?? 0
        let earned = await earnedTask ?? 0
        let earnedTrophies = await earnedTrophiesTask ?? []

        let monday = TreasuryService.mondayOfWeek(for: weekOf)
        let weekLogs = logs.filter { $0.weekOf == monday }
        let completed = weekLogs.filter {
            $0.verificationStatus == .autoApproved
                || $0.verificationStatus == .verified
        }

        return HeroSummary(
            profile: hero,
            weeklyQuestsCompleted: completed.count,
            weeklyQuestsTotal: quests.count,
            weeklyGoldEarned: earned,
            currentStreak: streak,
            trophiesEarned: earnedTrophies.count
        )
    }

    func rebuildLists(profiles: [Profile], quests: [Quest], logs: [QuestCompletion], ledgers: [LedgerEntry]) {
        let weekOf = QuestService.mondayOfWeek(for: Date())

        // Mirror the authoritative `TreasuryService.weeklyBreakdown` window so the
        // cache-rebuild path produces byte-identical `weeklyGoldEarned` values to
        // the async `buildHeroSummary` path. `weekOf` is already a Monday from
        // `QuestService.mondayOfWeek`; re-normalize through TreasuryService for
        // exact parity, then derive the closed `[start, end]` week interval used
        // to bound both quest logs and ledger entries below.
        let monday = TreasuryService.mondayOfWeek(for: weekOf)
        let weekRange = TreasuryService.weekRange(starting: monday)
        let questByID = Dictionary(
            quests.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )

        let active = profiles.filter(\.isActive)
        heroes = active
            .filter { $0.role == .hero }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        parents = active
            .filter(\.role.isParent)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        var heroSummaries: [HeroSummary] = []
        heroSummaries.reserveCapacity(heroes.count)

        for hero in heroes {
            let heroQuests = quests.filter { $0.assignee.recordID == hero.id && $0.weekOf == weekOf }
            let heroLogs = logs.filter { $0.completedBy.recordID == hero.id && $0.weekOf == weekOf }
            let completed = heroLogs.filter {
                $0.verificationStatus == .autoApproved || $0.verificationStatus == .verified
            }

            // Compute `weeklyGoldEarned` exactly as `TreasuryService.weeklyBreakdown`
            // does so the cache-rebuild and async-refresh paths agree byte-for-byte:
            //   goldFromQuests (slain logs this week, All-or-Nothing-gated) + bonusGold
            //   (positive ledger entries this week). Spending and unbounded sums are
            //   excluded — the prior implementation summed all `amount`s since Monday,
            //   which double-counted spending as negative and omitted quest-completion
            //   gold entirely, flipping the hero card between refresh() and rebuild().
            let weekLogs = logs.filter {
                $0.completedBy.recordID == hero.id && weekRange.contains($0.weekOf)
            }
            let slainLogs = weekLogs.filter {
                $0.verificationStatus == .verified
                    || $0.verificationStatus == .autoApproved
            }
            var goldFromQuests = slainLogs.reduce(into: 0.0) { acc, log in
                if let quest = questByID[log.quest.recordID] {
                    acc += quest.goldReward
                }
            }
            let assignedQuests = quests.filter {
                $0.assignee.recordID == hero.id && weekRange.contains($0.weekOf)
            }
            if hero.payoutPolicy == .allOrNothing,
               !assignedQuests.isEmpty,
               slainLogs.count < assignedQuests.count
            {
                goldFromQuests = 0
            }

            let heroLedgers = ledgers.filter {
                $0.profile.recordID == hero.id && weekRange.contains($0.date)
            }
            let bonusGold = heroLedgers
                .filter { $0.amount > 0 }
                .reduce(0.0) { $0 + $1.amount }
            let earned = goldFromQuests + bonusGold

            let existing = weekSummary?.heroSummaries.first { $0.profile.id == hero.id }
            let streak = existing?.currentStreak ?? 0
            let trophies = existing?.trophiesEarned ?? 0

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
        syncRefreshTask?.cancel()
        syncRefreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            // Snapshot the display-name map BEFORE refresh so we can compare
            // pre- vs post-refresh. `refresh()` overwrites lastHeroDisplayNames
            // at the end, so a comparison against lastHeroDisplayNames would
            // always be true (the bug) and retry every .recordChanged event.
            let preRefreshNames = lastHeroDisplayNames

            await refresh()

            // Build current names from the freshly-refreshed heroes.
            let currentNames = heroes.reduce(into: [String: String]()) {
                $0[$1.id.recordName] = $1.displayName
            }
            // Names unchanged across the refresh ⇒ CloudKit read returned stale
            // (pre-rename) data and the silent push was likely a Profile rename
            // whose CloudKit propagation is lagging. Schedule a late retry.
            if currentNames == preRefreshNames {
                scheduleLatePropagationRetry()
            }
        }
    }

    private func scheduleLatePropagationRetry() {
        syncRefreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await refresh()
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
        lastHeroDisplayNames = [:]
        syncRefreshTask?.cancel()
        syncRefreshTask = nil
    }
}

struct WeekendSummary: Equatable, Sendable {
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

struct HeroSummary: Equatable, Identifiable, Sendable {
    var id: CKRecord.ID {
        profile.id
    }

    let profile: Profile

    let weeklyQuestsCompleted: Int

    let weeklyQuestsTotal: Int

    let weeklyGoldEarned: Double

    let currentStreak: Int

    let trophiesEarned: Int

    var avatarRenderSpec: AvatarRenderSpec?
}
