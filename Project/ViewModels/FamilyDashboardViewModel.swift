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

    func refresh(syncEngine: SyncEngine? = nil) async {
        guard appState.family != nil else {
            heroes = []
            parents = []
            weekSummary = nil
            return
        }

        isLoading = true
        defer { isLoading = false }

        await ensureActiveShareURL()
        if let family = appState.family {
            try? await achievements.seedDefaultAchievements(family: family)
        }
        if let syncEngine {
            await syncEngine.incrementalSync(familyRecordName: appState.family?.id.recordName, forceFullFetch: true)
        }
    }

    @MainActor
    func ensureActiveShareURL() async {
        guard appState.isZoneOwner else { return }
        guard appState.activeShareURL == nil else { return }
        guard let zoneID = appState.familyZoneID, let family = appState.family else { return }
        let cloudKit = questService.cloudKitReference
        do {
            appState.activeShareURL = try await cloudKit.fetchOrCreateShareURL(in: zoneID, rootRecordID: family.id)
        } catch {
            logger.error("Failed to fetch or create active share URL: \(error, privacy: .private)")
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
        let familyName = appState.family?.id.recordName

        let familyPayoutDay = appState.family?.payoutDay ?? .sunday
        let active = profiles.filter(\.isActive)
        let computedHeroes = active
            .filter { $0.roleEnum == .hero }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let computedParents = active
            .filter { $0.roleEnum?.isParent == true }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        var heroSummaries: [HeroSummary] = []
        heroSummaries.reserveCapacity(computedHeroes.count)

        for hero in computedHeroes {
            let heroPayoutDay = hero.payoutDayEnum ?? familyPayoutDay
            let heroWeekOf = WeekMath.startOfWeek(for: Date(), payoutDay: heroPayoutDay)
            let heroWeekRange = WeekMath.weekRange(starting: heroWeekOf)

            let heroQuests = quests.filter { $0.assigneeRecordName == hero.recordName && heroWeekRange.contains($0.weekOf) }
            let heroLogs = logs.filter { $0.completerRecordName == hero.recordName && (heroWeekRange.contains($0.weekOf) || heroWeekRange.contains($0.completedDate)) }

            let approvedLogs = heroLogs.filter {
                $0.verificationStatusEnum == .autoApproved || $0.verificationStatusEnum == .verified
            }

            let fullyCompletedQuestsCount = heroQuests.filter { quest in
                let qApprovedLogs = approvedLogs.filter { $0.questRecordName == quest.recordName }
                return GoldCalculation.isFullyCompleted(quest: quest, approvedCount: qApprovedLogs.count)
            }.count

            let heroPeriod = allowancePeriods.first {
                $0.profileRecordName == hero.recordName &&
                    Calendar.iso8601UTC.isDate($0.weekOf, inSameDayAs: heroWeekOf)
            }
            let isPeriodPaid = heroPeriod?.statusEnum == .paid

            let earned: Double
            if isPeriodPaid {
                earned = 0.0
            } else {
                let goldFromQuests = GoldCalculation.netWeeklyGold(
                    quests: quests,
                    logs: logs,
                    profileRecordName: hero.recordName,
                    payoutPolicy: hero.payoutPolicyEnum,
                    weekRange: heroWeekRange
                )

                let heroLedgers = ledgers.filter {
                    $0.profileRecordName == hero.recordName && heroWeekRange.contains($0.date)
                }
                let bonusGold = heroLedgers
                    .filter { $0.amount > 0 && $0.source != "quest" }
                    .reduce(0.0) { $0 + $1.amount }
                earned = goldFromQuests + bonusGold
            }

            let streakLogs = logs.filter { $0.completerRecordName == hero.recordName }
            let streak = StreakCalculator.computeStreak(from: streakLogs)
            let trophies = profileAchievements
                .filter { $0.profileRecordName == hero.recordName }
                .count

            heroSummaries.append(HeroSummary(
                profile: hero,
                weeklyQuestsCompleted: fullyCompletedQuestsCount,
                weeklyQuestsTotal: heroQuests.count,
                weeklyGoldEarned: earned,
                currentStreak: streak,
                trophiesEarned: trophies
            ))
        }

        let totalEarned = heroSummaries.reduce(into: 0.0) { $0 += $1.weeklyGoldEarned }
        let totalQuests = heroSummaries.reduce(into: 0) { $0 += $1.weeklyQuestsCompleted }
        let computedWeekSummary = WeekendSummary(
            weekOf: WeekMath.startOfWeek(for: Date(), payoutDay: familyPayoutDay),
            totalEarned: totalEarned,
            totalQuestsCompleted: totalQuests,
            heroSummaries: heroSummaries
        )

        let computedPastPayouts = allowancePeriods
            .filter { familyName == nil || $0.familyRecordName == familyName }
            .sorted { $0.weekOf > $1.weekOf }

        heroes = computedHeroes
        parents = computedParents
        weekSummary = computedWeekSummary
        pastPayouts = computedPastPayouts
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
        // SyncEngine's incrementalSync handles writing incoming push changes to
        // SwiftData, which automatically re-fires `.onChange` → `rebuildLists()`.
    }

    func unsubscribeFromSyncEvents(_ coordinator: AppSyncCoordinator) {
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
    }
}

struct WeekendSummary: Equatable {
    let weekOf: Date

    let totalEarned: Double

    /// Amount pending payout for non-real-time heroes only.
    /// Real-time heroes' weekly gold is disbursed immediately on
    /// each quest completion, so it is never "pending" a weekly batch.
    var pendingPayoutAmount: Double {
        heroSummaries.reduce(into: 0.0) { acc, hero in
            if hero.profile.payoutPolicyEnum != .realTime {
                acc += hero.weeklyGoldEarned
            }
        }
    }

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
