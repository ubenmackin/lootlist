//
//  DashboardMetricsCalculator.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import Foundation

/// Pure calculator for dashboard metrics derived from SwiftData cache rows.
/// No CloudKit or service dependencies — fully deterministic from in-memory arrays
/// so it is trivially unit-testable.
enum DashboardMetricsCalculator {
    struct Metrics {
        let weekSummary: WeekendSummary?
        let pastPayouts: [AllowancePeriodCache]
        let familyOutflow: Double
        let pendingReviewCount: Int
        let childAccountCards: [ChildAccountCard]
    }

    /// Family payout context bundled to keep `calculate` within the
    /// `function_parameter_count` limit while remaining CloudKit-free.
    struct FamilyContext {
        let recordName: String?
        let payoutDay: PayoutDay
        let payoutPolicy: PayoutPolicy?

        init(
            recordName: String? = nil,
            payoutDay: PayoutDay = .sunday,
            payoutPolicy: PayoutPolicy? = nil
        ) {
            self.recordName = recordName
            self.payoutDay = payoutDay
            self.payoutPolicy = payoutPolicy
        }
    }

    /// Canonical pure calculation from cached rows plus explicit family context.
    /// Family context is passed explicitly so the type remains CloudKit-free while
    /// still reproducing the payout-day-aware week logic from the ViewModel.
    static func calculate(
        profiles: [ProfileCache],
        quests: [QuestCache],
        logs: [QuestCompletionCache],
        ledgers: [LedgerEntryCache],
        allowancePeriods: [AllowancePeriodCache],
        profileAchievements: [ProfileAchievementCache],
        familyContext: FamilyContext
    ) -> Metrics {
        let roster = RosterViewState(profiles: profiles)
        let computedHeroes = roster.heroes

        var heroSummaries: [HeroSummary] = []
        heroSummaries.reserveCapacity(computedHeroes.count)

        for hero in computedHeroes {
            let heroPayoutDay = hero.payoutDayEnum ?? familyContext.payoutDay
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
                    WeekMath.startOfWeek(for: $0.weekOf, payoutDay: heroPayoutDay) == heroWeekOf
            }
            let isPeriodPaid = heroPeriod?.statusEnum == .paid

            let questGold: Double
            let bonusGold: Double
            if isPeriodPaid {
                questGold = 0.0
                bonusGold = 0.0
            } else {
                let effectivePolicy = hero.payoutPolicyEnum ?? familyContext.payoutPolicy ?? .perQuest
                questGold = GoldCalculation.netWeeklyGold(
                    quests: quests,
                    logs: logs,
                    profileRecordName: hero.recordName,
                    payoutPolicy: effectivePolicy,
                    weekRange: heroWeekRange
                )

                let heroLedgers = ledgers.filter {
                    $0.profileRecordName == hero.recordName && heroWeekRange.contains($0.date)
                }
                bonusGold = heroLedgers
                    .filter { $0.amount > 0 && $0.sourceEnum != .quest }
                    .reduce(0.0) { $0 + $1.amount }
            }
            let earned = questGold + bonusGold

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
                weeklyQuestGold: questGold,
                currentStreak: streak,
                trophiesEarned: trophies
            ))
        }

        let totalEarned = heroSummaries.reduce(into: 0.0) { $0 += $1.weeklyGoldEarned }
        let totalQuests = heroSummaries.reduce(into: 0) { $0 += $1.weeklyQuestsCompleted }
        let computedWeekSummary = WeekendSummary(
            weekOf: WeekMath.startOfWeek(for: Date(), payoutDay: familyContext.payoutDay),
            totalEarned: totalEarned,
            totalQuestsCompleted: totalQuests,
            heroSummaries: heroSummaries
        )

        let computedPastPayouts = allowancePeriods
            .filter { familyContext.recordName == nil || $0.familyRecordName == familyContext.recordName }
            .sorted { $0.weekOf > $1.weekOf }

        let heroRecordNames = Set(computedHeroes.map(\.recordName))
        let heroLedgerEntries = ledgers.filter { heroRecordNames.contains($0.profileRecordName) }
        var computedFamilyOutflow: Double = 0
        for hero in computedHeroes {
            let heroEntries = heroLedgerEntries.filter { $0.profileRecordName == hero.recordName }
            let balances = BucketService.bucketBalances(for: heroEntries, profileRecordName: hero.recordName)
            let legacyUnattributed = heroEntries.filter { $0.bucketKindEnum == nil && $0.sourceEnum != .transfer }.reduce(0) { $0 + $1.amount }
            computedFamilyOutflow += balances.values.reduce(0, +) + legacyUnattributed
        }

        let pendingLogs = logs.filter { $0.verificationStatusEnum == .pending }
        let computedPendingReviewCount = pendingLogs.count

        let computedChildAccountCards: [ChildAccountCard] = computedHeroes.map { hero in
            let heroEntries = heroLedgerEntries.filter { $0.profileRecordName == hero.recordName }
            let balances = BucketService.bucketBalances(for: heroEntries, profileRecordName: hero.recordName)
            let legacyUnattributed = heroEntries.filter { $0.bucketKindEnum == nil && $0.sourceEnum != .transfer }.reduce(0) { $0 + $1.amount }
            let heroBalance = balances.values.reduce(0, +) + legacyUnattributed
            let heroPending = pendingLogs
                .filter { $0.completerRecordName == hero.recordName }
                .count
            return ChildAccountCard(profile: hero, balance: heroBalance, pendingReviewCount: heroPending)
        }

        return Metrics(
            weekSummary: computedWeekSummary,
            pastPayouts: computedPastPayouts,
            familyOutflow: computedFamilyOutflow,
            pendingReviewCount: computedPendingReviewCount,
            childAccountCards: computedChildAccountCards
        )
    }

    /// Convenience pure entry point matching the canonical 6-array tuple described in
    /// the decomposition task. Defaults family context to nil/.sunday so pure unit
    /// tests can exercise metric logic without CloudKit family scaffolding.
    static func calculate(
        profiles: [ProfileCache],
        quests: [QuestCache],
        logs: [QuestCompletionCache],
        ledgers: [LedgerEntryCache],
        allowancePeriods: [AllowancePeriodCache],
        profileAchievements: [ProfileAchievementCache]
    ) -> Metrics {
        calculate(
            profiles: profiles,
            quests: quests,
            logs: logs,
            ledgers: ledgers,
            allowancePeriods: allowancePeriods,
            profileAchievements: profileAchievements,
            familyContext: FamilyContext()
        )
    }
}
