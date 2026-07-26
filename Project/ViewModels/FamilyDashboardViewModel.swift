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
    }

    func loadPastPayouts(includeActive: Bool = true) async {
        guard let family = appState.family else {
            pastPayouts = []
            return
        }

        isLoadingPayouts = true
        defer { isLoadingPayouts = false }

        let familyName = family.id.recordName
        if let cache = appState.cacheService {
            let all = cache.fetchAllowancePeriods(family: familyName)
            pastPayouts = includeActive ? all : all.filter { $0.status == PayoutStatus.paid.rawValue }
        }
    }

    private func buildHeroSummary(for hero: ProfileCache,
                                  weekOf: Date) async -> HeroSummary
    {
        let zoneID = questService.cloudKitReference.resolvedZoneID
        let domainHero = hero.toProfile(zoneID: zoneID)
        async let questsTask: [Quest]? = try? questService.fetchActiveQuests(
            profile: domainHero, weekOf: weekOf
        )
        async let logsTask: [QuestCompletion]? = try? questService.fetchQuestLogs(
            for: domainHero
        )
        async let streakTask: Int? = try? questService.fetchStreak(for: domainHero)
        async let earnedTask: Double? = try? treasury.weeklyBreakdown(
            profile: domainHero, weekOf: weekOf
        ).totalEarned

        async let earnedTrophiesTask: [ProfileAchievement]? = try? achievements.fetchEarned(
            profile: domainHero
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

    func rebuildLists(profiles: [ProfileCache], quests: [QuestCache], logs: [QuestCompletionCache], ledgers: [LedgerEntryCache]) {
        let weekOf = QuestService.mondayOfWeek(for: Date())
        let monday = TreasuryService.mondayOfWeek(for: weekOf)
        let weekRange = TreasuryService.weekRange(starting: monday)
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

            let existing = weekSummary?.heroSummaries.first { $0.profile.recordName == hero.recordName }
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
                $0[$1.recordName] = $1.displayName
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
