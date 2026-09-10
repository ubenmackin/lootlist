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
        let familyOutflow: Int64
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
        familyContext: FamilyContext,
        templates: [QuestTemplateCache]
    ) -> Metrics {
        let roster = RosterViewState(profiles: profiles)
        let computedHeroes = roster.heroes
        // WHY day count wins: legacy quest rows keep stale targetCount after template gains days.
        let templatesByID = SpecificDaysHelper.templatesByID(templates)

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
                // WHY day count wins: stale targetCount would under-count specific-days checklists.
                let target = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
                return GoldCalculation.isFullyCompleted(quest: quest, approvedCount: qApprovedLogs.count, effectiveTarget: target)
            }.count

            let heroPeriod = allowancePeriods.first {
                $0.profileRecordName == hero.recordName &&
                    WeekMath.startOfWeek(for: $0.weekOf, payoutDay: heroPayoutDay) == heroWeekOf
            }
            let isPeriodPaid = heroPeriod?.statusEnum == .paid

            let questGold: Int64
            let bonusGold: Int64
            if isPeriodPaid {
                questGold = 0
                bonusGold = 0
            } else {
                let effectivePolicy = hero.payoutPolicyEnum ?? familyContext.payoutPolicy ?? .perQuest
                questGold = GoldCalculation.netWeeklyPennies(
                    quests: quests,
                    logs: logs,
                    profileRecordName: hero.recordName,
                    payoutPolicy: effectivePolicy,
                    weekRange: heroWeekRange,
                    templatesByID: templatesByID
                )

                let heroLedgers = ledgers.filter {
                    $0.profileRecordName == hero.recordName && heroWeekRange.contains($0.date)
                }
                bonusGold = heroLedgers
                    // WHY single-count: goal markers reuse already-counted funds and transfers move between buckets.
                    .filter { BucketService.isBonusCounted($0) }
                    .reduce(0) { $0 + $1.amount }
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

        let totalEarned = heroSummaries.reduce(into: Int64(0)) { $0 += $1.weeklyGoldEarned }
        let totalQuests = heroSummaries.reduce(into: 0) { $0 += $1.weeklyQuestsCompleted }
        let computedWeekSummary = WeekendSummary(
            weekOf: WeekMath.startOfWeek(for: Date(), payoutDay: familyContext.payoutDay),
            totalEarned: totalEarned,
            totalQuestsCompleted: totalQuests,
            heroSummaries: heroSummaries
        )

        let heroRecordNames = Set(profiles.filter { $0.roleEnum == .hero }.map(\.recordName))
        let computedPastPayouts = allowancePeriods
            .filter { (familyContext.recordName == nil || $0.familyRecordName == familyContext.recordName) && heroRecordNames.contains($0.profileRecordName) }
            .sorted { $0.weekOf > $1.weekOf }

        let heroLedgerEntries = ledgers.filter { heroRecordNames.contains($0.profileRecordName) }
        var computedFamilyOutflow: Int64 = 0
        for hero in computedHeroes {
            let heroEntries = heroLedgerEntries.filter { $0.profileRecordName == hero.recordName }
            computedFamilyOutflow += heroTotalBalance(heroEntries: heroEntries, profileRecordName: hero.recordName)
        }

        let pendingLogs = logs.filter { $0.verificationStatusEnum == .pending }
        let computedPendingReviewCount = pendingLogs.count

        let computedChildAccountCards: [ChildAccountCard] = computedHeroes.map { hero in
            let heroEntries = heroLedgerEntries.filter { $0.profileRecordName == hero.recordName }
            let heroBalance = heroTotalBalance(heroEntries: heroEntries, profileRecordName: hero.recordName)
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

    static func calculate(
        profiles: [ProfileCache],
        quests: [QuestCache],
        logs: [QuestCompletionCache],
        ledgers: [LedgerEntryCache],
        allowancePeriods: [AllowancePeriodCache],
        profileAchievements: [ProfileAchievementCache],
        templates: [QuestTemplateCache]
    ) -> Metrics {
        calculate(
            profiles: profiles,
            quests: quests,
            logs: logs,
            ledgers: ledgers,
            allowancePeriods: allowancePeriods,
            profileAchievements: profileAchievements,
            familyContext: FamilyContext(),
            templates: templates
        )
    }

    /// WHY one helper: bucket sum is the total on every surface.
    private static func heroTotalBalance(heroEntries: [LedgerEntryCache], profileRecordName: String) -> Int64 {
        BucketService.totalBalance(for: heroEntries, profileRecordName: profileRecordName)
    }
}

/// WHY value snapshots: live @Model rows never cross isolation, so the fingerprinter hashes Sendable copies.
struct DashboardProfileSnapshot: Sendable, Hashable {
    let recordName: String
    let familyRecordName: String
    let displayName: String
    let role: String
    let isActive: Bool
    let payoutDay: String?
    let payoutPolicy: String?
    let avatarName: String?
    let avatarEmoji: String?
    let avatarClass: String?
    let splitPercentSpend: Int
    let splitPercentShort: Int
    let splitPercentLong: Int

    init(from row: ProfileCache) {
        recordName = row.recordName
        familyRecordName = row.familyRecordName
        displayName = row.displayName
        role = row.role
        isActive = row.isActive
        payoutDay = row.payoutDay
        payoutPolicy = row.payoutPolicy
        avatarName = row.avatarName
        avatarEmoji = row.avatarEmoji
        avatarClass = row.avatarClass
        splitPercentSpend = row.splitPercentSpend
        splitPercentShort = row.splitPercentShort
        splitPercentLong = row.splitPercentLong
    }
}

/// WHY value snapshot: quest rows hash without touching live storage off isolation.
struct DashboardQuestSnapshot: Sendable, Hashable {
    let recordName: String
    let familyRecordName: String
    let assigneeRecordName: String
    let templateRecordName: String
    let weekOf: Date
    let questName: String
    let isActive: Bool
    let goldReward: Int64
    let xpReward: Int
    let targetCount: Int
    let scheduleType: String
    let isAllOrNothing: Bool
    let claimedByProfileRecordName: String?
    let claimedAt: Date?
    let descriptionText: String?

    init(from row: QuestCache) {
        recordName = row.recordName
        familyRecordName = row.familyRecordName
        assigneeRecordName = row.assigneeRecordName
        templateRecordName = row.templateRecordName
        weekOf = row.weekOf
        questName = row.questName
        isActive = row.isActive
        goldReward = row.goldReward
        xpReward = row.xpReward
        targetCount = row.targetCount
        scheduleType = row.scheduleType
        isAllOrNothing = row.isAllOrNothing
        claimedByProfileRecordName = row.claimedByProfileRecordName
        claimedAt = row.claimedAt
        descriptionText = row.descriptionText
    }
}

/// WHY value snapshot: completion routing fields alone bust the memo.
struct DashboardCompletionSnapshot: Sendable, Hashable {
    let recordName: String
    let familyRecordName: String
    let questRecordName: String
    let completerRecordName: String
    let weekOf: Date
    let completedDate: Date
    let verificationStatus: String
    let approvalMode: String

    init(from row: QuestCompletionCache) {
        recordName = row.recordName
        familyRecordName = row.familyRecordName
        questRecordName = row.questRecordName
        completerRecordName = row.completerRecordName
        weekOf = row.weekOf
        completedDate = row.completedDate
        verificationStatus = row.verificationStatus
        approvalMode = row.approvalMode
    }
}

/// WHY value snapshot: only money fields feed balances.
struct DashboardLedgerSnapshot: Sendable, Hashable {
    let recordName: String
    let familyRecordName: String
    let profileRecordName: String
    let amount: Int64
    let source: String
    let bucketKind: String?
    let fromBucket: String?
    let toBucket: String?
    let date: Date

    init(from row: LedgerEntryCache) {
        recordName = row.recordName
        familyRecordName = row.familyRecordName
        profileRecordName = row.profileRecordName
        amount = row.amount
        source = row.source
        bucketKind = row.bucketKind
        fromBucket = row.fromBucket
        toBucket = row.toBucket
        date = row.date
    }
}

/// WHY value snapshot: payout rows hash without live faults.
struct DashboardPeriodSnapshot: Sendable, Hashable {
    let recordName: String
    let familyRecordName: String
    let profileRecordName: String
    let weekOf: Date
    let status: String
    let totalEarned: Int64
    let questsCompleted: Int
    let questsTotal: Int
    let paidAmount: Int64?
    let paidDate: Date?

    init(from row: AllowancePeriodCache) {
        recordName = row.recordName
        familyRecordName = row.familyRecordName
        profileRecordName = row.profileRecordName
        weekOf = row.weekOf
        status = row.status
        totalEarned = row.totalEarned
        questsCompleted = row.questsCompleted
        questsTotal = row.questsTotal
        paidAmount = row.paidAmount
        paidDate = row.paidDate
    }
}

/// WHY value snapshot: trophy rows hash without live faults.
struct DashboardProfileAchievementSnapshot: Sendable, Hashable {
    let recordName: String
    let familyRecordName: String
    let profileRecordName: String
    let achievementRecordName: String
    let earnedDate: Date

    init(from row: ProfileAchievementCache) {
        recordName = row.recordName
        familyRecordName = row.familyRecordName
        profileRecordName = row.profileRecordName
        achievementRecordName = row.achievementRecordName
        earnedDate = row.earnedDate
    }
}

/// WHY value snapshot: achievement rows hash without live faults.
struct DashboardAchievementSnapshot: Sendable, Hashable {
    let recordName: String
    let familyRecordName: String
    let name: String
    let requirementType: String
    let requirementValue: Int

    init(from row: AchievementCache) {
        recordName = row.recordName
        familyRecordName = row.familyRecordName
        name = row.name
        requirementType = row.requirementType
        requirementValue = row.requirementValue
    }
}

/// WHY value snapshot: only scheduling fields feed targets.
struct DashboardTemplateSnapshot: Sendable, Hashable {
    let recordName: String
    let familyRecordName: String
    let name: String
    let goldReward: Int64
    let xpReward: Int
    let isActive: Bool
    let targetCount: Int
    let scheduleType: String
    let specificDays: [String]?
    let isAllOrNothing: Bool
    let approvalMode: String

    init(from row: QuestTemplateCache) {
        recordName = row.recordName
        familyRecordName = row.familyRecordName
        name = row.name
        goldReward = row.goldReward
        xpReward = row.xpReward
        isActive = row.isActive
        targetCount = row.targetCount
        scheduleType = row.scheduleType
        specificDays = row.specificDays
        isAllOrNothing = row.isAllOrNothing
        approvalMode = row.approvalMode
    }
}

/// Pure, isolation-free fingerprinting for dashboard memoization.
/// WHY dedicated type: @Query refires on unrelated writes, so the container hashes value snapshots off isolation.
enum DashboardMetricsFingerprinter {
    /// Value snapshot bundle keeping `rebuildKey` within the `function_parameter_count` limit.
    struct Inputs: Sendable {
        let profiles: [DashboardProfileSnapshot]
        let quests: [DashboardQuestSnapshot]
        let logs: [DashboardCompletionSnapshot]
        let ledgers: [DashboardLedgerSnapshot]
        let allowancePeriods: [DashboardPeriodSnapshot]
        let profileAchievements: [DashboardProfileAchievementSnapshot]
        let achievements: [DashboardAchievementSnapshot]
        let templates: [DashboardTemplateSnapshot]
        let familyContext: DashboardMetricsCalculator.FamilyContext
        let freshnessVersion: Int
    }

    static func rebuildKey(_ inputs: Inputs) -> Int {
        var hasher = Hasher()
        hasher.combine(fold(inputs.profiles.map { fingerprint(for: $0) }))
        hasher.combine(fold(inputs.quests.map { fingerprint(for: $0) }))
        hasher.combine(fold(inputs.logs.map { fingerprint(for: $0) }))
        hasher.combine(fold(inputs.ledgers.map { fingerprint(for: $0) }))
        hasher.combine(fold(inputs.allowancePeriods.map { fingerprint(for: $0) }))
        hasher.combine(fold(inputs.profileAchievements.map { fingerprint(for: $0) }))
        hasher.combine(fold(inputs.achievements.map { fingerprint(for: $0) }))
        hasher.combine(fold(inputs.templates.map { fingerprint(for: $0) }))
        hasher.combine(fingerprint(familyContext: inputs.familyContext, freshnessVersion: inputs.freshnessVersion))
        return hasher.finalize()
    }

    /// WHY order-independent: XOR folding avoids sorting large tables while count disambiguates size changes.
    static func fold(_ hashes: [Int]) -> Int {
        var acc = hashes.count
        for hash in hashes {
            acc ^= hash
        }
        return acc
    }

    /// WHY tiny hashes: one row types alone so the checker never solves a mega-interpolation.
    static func fingerprint(for snapshot: DashboardProfileSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.recordName)
        hasher.combine(snapshot.familyRecordName)
        hasher.combine(snapshot.displayName)
        hasher.combine(snapshot.role)
        hasher.combine(snapshot.isActive)
        hasher.combine(snapshot.payoutDay ?? "-")
        hasher.combine(snapshot.payoutPolicy ?? "-")
        hasher.combine(snapshot.avatarName ?? "-")
        hasher.combine(snapshot.avatarEmoji ?? "-")
        hasher.combine(snapshot.avatarClass ?? "-")
        hasher.combine(snapshot.splitPercentSpend)
        hasher.combine(snapshot.splitPercentShort)
        hasher.combine(snapshot.splitPercentLong)
        return hasher.finalize()
    }

    /// WHY tiny hashes: one row types alone so the checker never solves a mega-interpolation.
    static func fingerprint(for snapshot: DashboardQuestSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.recordName)
        hasher.combine(snapshot.familyRecordName)
        hasher.combine(snapshot.assigneeRecordName)
        hasher.combine(snapshot.templateRecordName)
        hasher.combine(Int(snapshot.weekOf.timeIntervalSince1970))
        hasher.combine(snapshot.goldReward)
        hasher.combine(snapshot.xpReward)
        hasher.combine(snapshot.targetCount)
        hasher.combine(snapshot.scheduleType)
        hasher.combine(snapshot.isAllOrNothing)
        hasher.combine(snapshot.isActive)
        hasher.combine(snapshot.questName)
        hasher.combine(snapshot.claimedByProfileRecordName ?? "-")
        hasher.combine(snapshot.claimedAt.map { Int($0.timeIntervalSince1970) } ?? -1)
        hasher.combine(snapshot.descriptionText ?? "-")
        return hasher.finalize()
    }

    /// WHY tiny hashes: one row types alone so the checker never solves a mega-interpolation.
    static func fingerprint(for snapshot: DashboardCompletionSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.recordName)
        hasher.combine(snapshot.familyRecordName)
        hasher.combine(snapshot.questRecordName)
        hasher.combine(snapshot.completerRecordName)
        hasher.combine(Int(snapshot.weekOf.timeIntervalSince1970))
        hasher.combine(Int(snapshot.completedDate.timeIntervalSince1970))
        hasher.combine(snapshot.verificationStatus)
        hasher.combine(snapshot.approvalMode)
        // WHY metrics-only: verifier and credit markers never feed counts, so only routing fields bust.
        return hasher.finalize()
    }

    /// WHY tiny hashes: one row types alone so the checker never solves a mega-interpolation.
    static func fingerprint(for snapshot: DashboardLedgerSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.recordName)
        hasher.combine(snapshot.familyRecordName)
        hasher.combine(snapshot.profileRecordName)
        hasher.combine(snapshot.amount)
        hasher.combine(snapshot.source)
        hasher.combine(snapshot.bucketKind ?? "-")
        hasher.combine(snapshot.fromBucket ?? "-")
        hasher.combine(snapshot.toBucket ?? "-")
        hasher.combine(Int(snapshot.date.timeIntervalSince1970))
        // WHY metrics-only: description and location never feed balances, so only money fields bust.
        return hasher.finalize()
    }

    /// WHY tiny hashes: one row types alone so the checker never solves a mega-interpolation.
    static func fingerprint(for snapshot: DashboardPeriodSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.recordName)
        hasher.combine(snapshot.familyRecordName)
        hasher.combine(snapshot.profileRecordName)
        hasher.combine(Int(snapshot.weekOf.timeIntervalSince1970))
        hasher.combine(snapshot.status)
        hasher.combine(snapshot.totalEarned)
        hasher.combine(snapshot.questsCompleted)
        hasher.combine(snapshot.questsTotal)
        hasher.combine(snapshot.paidAmount ?? -1)
        hasher.combine(snapshot.paidDate.map { Int($0.timeIntervalSince1970) } ?? -1)
        return hasher.finalize()
    }

    /// WHY tiny hashes: one row types alone so the checker never solves a mega-interpolation.
    static func fingerprint(for snapshot: DashboardProfileAchievementSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.recordName)
        hasher.combine(snapshot.familyRecordName)
        hasher.combine(snapshot.profileRecordName)
        hasher.combine(snapshot.achievementRecordName)
        hasher.combine(Int(snapshot.earnedDate.timeIntervalSince1970))
        return hasher.finalize()
    }

    /// WHY tiny hashes: one row types alone so the checker never solves a mega-interpolation.
    static func fingerprint(for snapshot: DashboardAchievementSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.recordName)
        hasher.combine(snapshot.familyRecordName)
        hasher.combine(snapshot.name)
        hasher.combine(snapshot.requirementType)
        hasher.combine(snapshot.requirementValue)
        return hasher.finalize()
    }

    /// WHY tiny hashes: one row types alone so the checker never solves a mega-interpolation.
    static func fingerprint(for snapshot: DashboardTemplateSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.recordName)
        hasher.combine(snapshot.familyRecordName)
        hasher.combine(snapshot.name)
        hasher.combine(snapshot.goldReward)
        hasher.combine(snapshot.xpReward)
        hasher.combine(snapshot.isActive)
        hasher.combine(snapshot.targetCount)
        hasher.combine(snapshot.scheduleType)
        if let specificDays = snapshot.specificDays {
            // WHY order-independent: day sets compare equal regardless of stored order.
            hasher.combine(fold(specificDays.map {
                var dayHasher = Hasher()
                dayHasher.combine($0)
                return dayHasher.finalize()
            }))
        } else {
            hasher.combine(fold([]))
        }
        hasher.combine(snapshot.isAllOrNothing)
        hasher.combine(snapshot.approvalMode)
        // WHY metrics-only: display fields never feed targets, so only scheduling fields bust.
        return hasher.finalize()
    }

    /// WHY tiny hashes: one row types alone so the checker never solves a mega-interpolation.
    static func fingerprint(familyContext: DashboardMetricsCalculator.FamilyContext, freshnessVersion: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(familyContext.recordName ?? "-")
        hasher.combine(familyContext.payoutDay.rawValue)
        hasher.combine(familyContext.payoutPolicy?.rawValue ?? "-")
        hasher.combine(freshnessVersion)
        return hasher.finalize()
    }
}
