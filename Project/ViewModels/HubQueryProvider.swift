//
//  HubQueryProvider.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import Foundation
import SwiftData

/// Shared store-level query setup and pure hub transforms for the child surfaces.
/// WHY single source: HeroHome and ChildHub built identical family+profile
/// predicates and stable sorts in their inits; one provider keeps the isolation
/// boundary and row ordering from drifting while views keep owning @Query.
enum HubQueryProvider {
    // MARK: - Scope

    /// Fail-closed family scope for predicate pushdown.
    static func targetFamily(_ familyRecordName: String?) -> String {
        familyRecordName ?? ""
    }

    // MARK: - Quest Predicates

    /// HeroHome semantics: profile resolves to an assignee slice, nil falls back to family-wide.
    static func questFilter(family: String, profile: String?) -> Predicate<QuestCache> {
        guard let targetProfile = profile?.trimmingCharacters(in: .whitespacesAndNewlines), !targetProfile.isEmpty else {
            return QuestCache.familyPredicate(familyRecordName: family)
        }
        return QuestCache.assignedPredicate(familyRecordName: family, assigneeRecordName: targetProfile)
    }

    /// ChildHub semantics: always profile-scoped, fail-closed to zero rows when empty.
    static func questScopedFilter(family: String, profile: String) -> Predicate<QuestCache> {
        QuestCache.assignedPredicate(familyRecordName: family, assigneeRecordName: profile)
    }

    // MARK: - Completion Predicates

    static func completionFilter(family: String, profile: String?) -> Predicate<QuestCompletionCache> {
        guard let targetProfile = profile?.trimmingCharacters(in: .whitespacesAndNewlines), !targetProfile.isEmpty else {
            return QuestCompletionCache.familyPredicate(familyRecordName: family)
        }
        return QuestCompletionCache.completerPredicate(familyRecordName: family, completerRecordName: targetProfile)
    }

    static func completionScopedFilter(family: String, profile: String) -> Predicate<QuestCompletionCache> {
        QuestCompletionCache.completerPredicate(familyRecordName: family, completerRecordName: profile)
    }

    // MARK: - Allowance / Gem / Goal / Ledger Predicates

    static func allowanceFilter(family: String, profile: String?) -> Predicate<AllowancePeriodCache> {
        guard let targetProfile = profile?.trimmingCharacters(in: .whitespacesAndNewlines), !targetProfile.isEmpty else {
            return AllowancePeriodCache.familyPredicate(familyRecordName: family)
        }
        return AllowancePeriodCache.profilePredicate(familyRecordName: family, profileRecordName: targetProfile)
    }

    static func allowanceScopedFilter(family: String, profile: String) -> Predicate<AllowancePeriodCache> {
        AllowancePeriodCache.profilePredicate(familyRecordName: family, profileRecordName: profile)
    }

    static func gemFilter(family: String, profile: String?) -> Predicate<GemLedgerCache> {
        guard let targetProfile = profile?.trimmingCharacters(in: .whitespacesAndNewlines), !targetProfile.isEmpty else {
            return GemLedgerCache.familyPredicate(familyRecordName: family)
        }
        return GemLedgerCache.profilePredicate(familyRecordName: family, profileRecordName: targetProfile)
    }

    static func goalFilter(family: String, profile: String?) -> Predicate<GoalCache> {
        guard let targetProfile = profile?.trimmingCharacters(in: .whitespacesAndNewlines), !targetProfile.isEmpty else {
            return GoalCache.familyPredicate(familyRecordName: family)
        }
        return GoalCache.profilePredicate(familyRecordName: family, profileRecordName: targetProfile)
    }

    static func goalScopedFilter(family: String, profile: String) -> Predicate<GoalCache> {
        GoalCache.profilePredicate(familyRecordName: family, profileRecordName: profile)
    }

    static func ledgerScopedFilter(family: String, profile: String) -> Predicate<LedgerEntryCache> {
        LedgerEntryCache.profilePredicate(familyRecordName: family, profileRecordName: profile)
    }

    // MARK: - Family-Scoped Predicates

    static func templateFilter(family: String) -> Predicate<QuestTemplateCache> {
        QuestTemplateCache.activeFamilyPredicate(familyRecordName: family)
    }

    static func profileFilter(family: String) -> Predicate<ProfileCache> {
        ProfileCache.familyPredicate(familyRecordName: family)
    }

    static func currentProfileFilter(family: String, profile: String?) -> Predicate<ProfileCache> {
        guard let targetProfile = profile?.trimmingCharacters(in: .whitespacesAndNewlines), !targetProfile.isEmpty else {
            return ProfileCache.familyPredicate(familyRecordName: family)
        }
        return ProfileCache.recordPredicate(recordName: targetProfile, familyRecordName: family)
    }

    static func currentProfileScopedFilter(family: String, profile: String) -> Predicate<ProfileCache> {
        ProfileCache.recordPredicate(recordName: profile, familyRecordName: family)
    }

    // MARK: - Viewer Row

    /// WHY single source: viewer-row predicate/sort/resolver was copied across hub views; one helper keeps empty-scope semantics identical.
    static func currentProfileSort() -> [SortDescriptor<ProfileCache>] {
        profileSort()
    }

    /// WHY session bridge: param identity wins with session fallback so bootstrap stays live before params propagate.
    static func resolveViewerRow(
        rows: [ProfileCache],
        profileRecordName: String?,
        fallbackRecordName: String?
    ) -> ProfileCache? {
        ProfileRowResolver.resolve(rows: rows, targetRecordName: profileRecordName ?? fallbackRecordName)
    }

    // MARK: - Stable Sorts

    /// WHY secondary recordName: keeps ForEach stable after CloudKit reorders.
    static func questSort() -> [SortDescriptor<QuestCache>] {
        [SortDescriptor(\QuestCache.weekOf, order: .reverse), SortDescriptor(\QuestCache.recordName)]
    }

    static func completionSort() -> [SortDescriptor<QuestCompletionCache>] {
        [SortDescriptor(\QuestCompletionCache.completedDate, order: .reverse), SortDescriptor(\QuestCompletionCache.recordName)]
    }

    static func templateSort() -> [SortDescriptor<QuestTemplateCache>] {
        [SortDescriptor(\QuestTemplateCache.name), SortDescriptor(\QuestTemplateCache.recordName)]
    }

    static func goalSort() -> [SortDescriptor<GoalCache>] {
        [SortDescriptor(\GoalCache.createdAt), SortDescriptor(\GoalCache.recordName)]
    }

    static func ledgerSort() -> [SortDescriptor<LedgerEntryCache>] {
        [SortDescriptor(\LedgerEntryCache.date, order: .reverse), SortDescriptor(\LedgerEntryCache.recordName)]
    }

    static func allowanceSort() -> [SortDescriptor<AllowancePeriodCache>] {
        [SortDescriptor(\AllowancePeriodCache.weekOf, order: .reverse), SortDescriptor(\AllowancePeriodCache.recordName)]
    }

    static func gemSort() -> [SortDescriptor<GemLedgerCache>] {
        [SortDescriptor(\GemLedgerCache.createdAt, order: .reverse), SortDescriptor(\GemLedgerCache.recordName)]
    }

    static func profileSort() -> [SortDescriptor<ProfileCache>] {
        [SortDescriptor(\ProfileCache.displayName), SortDescriptor(\ProfileCache.recordName)]
    }

    // MARK: - Shared Transforms (pure, no CloudKit)

    /// First-name derivation shared by hub headers so empty names fail closed to nil.
    static func firstName(displayName: String?) -> String? {
        guard let displayName, !displayName.isEmpty else { return nil }
        return displayName.split(separator: " ").first.map(String.init) ?? displayName
    }

    /// WHY shared predicate: checklist and wishlist must agree on what counts as a goal.
    static func hasListedGoal(goals: [GoalCache], profileName: String?) -> Bool {
        if let targetName = profileName?.trimmingCharacters(in: .whitespacesAndNewlines), !targetName.isEmpty {
            return goals.contains { $0.profileRecordName == targetName && $0.isListedGoal }
        }
        return goals.contains(where: \.isListedGoal)
    }

    static func recentLedgers(_ ledgers: [LedgerEntryCache], limit: Int = 7) -> [LedgerEntryCache] {
        Array(ledgers.prefix(limit))
    }

    static func staleBannerCount(profiles: Int, quests: Int, goals: Int, ledgers: Int) -> Int {
        profiles + quests + goals + ledgers
    }

    /// Pending-review completions shared by dashboard stat card and queue section.
    static func pendingCompletions(from completions: [QuestCompletionCache]) -> [QuestCompletionCache] {
        completions.filter { $0.verificationStatus == VerificationStatus.pending.rawValue }
    }

    /// Ledger sparkline points grouped by UTC dayKey so same-day entries sum once.
    static func ledgerSparklinePoints(from ledgers: [LedgerEntryCache]) -> [WeeklyEarningPoint] {
        let grouped = Dictionary(grouping: ledgers) { WeekMath.dayKey(for: $0.date) }
        return grouped.keys.sorted().suffix(7).compactMap { key in
            guard let entries = grouped[key] else { return nil }
            let bucketDate = WeekMath.date(fromDayKey: key) ?? entries.map(\.date).min() ?? Date()
            // WHY single-count: goal markers reuse deposit/quest pennies and transfers move between buckets.
            let totalPennies = entries.filter { BucketService.isCounted($0) }.reduce(Int64(0)) { $0 + $1.amount }
            let label = bucketDate.formatted(.dateTime.month(.abbreviated).day())
            return WeeklyEarningPoint(id: key, weekStart: bucketDate, label: label, amount: totalPennies)
        }
    }

    /// Six-week earning trend from allowance periods, optionally filtered to one hero.
    static func weeklyEarningPoints(
        periods: [AllowancePeriodCache],
        payoutDay: PayoutDay,
        selectedProfile: String?,
        now: Date = Date()
    ) -> [WeeklyEarningPoint] {
        let currentStart = WeekMath.startOfWeek(for: now, payoutDay: payoutDay)
        var result: [WeeklyEarningPoint] = []
        result.reserveCapacity(6)
        for offset in 0 ..< 6 {
            let weekStart = WeekMath.weekStart(byAddingWeeks: -(5 - offset), to: currentStart)
            let weekRange = WeekMath.weekRange(starting: weekStart)
            let label = weekStart.formatted(.dateTime.month(.abbreviated).day())
            let amountPennies: Int64 = if let selectedProfile, !selectedProfile.isEmpty {
                periods.filter {
                    $0.profileRecordName == selectedProfile && weekRange.contains($0.weekOf)
                }.reduce(Int64(0)) { $0 + $1.totalEarned }
            } else {
                periods.filter {
                    weekRange.contains($0.weekOf)
                }.reduce(Int64(0)) { $0 + $1.totalEarned }
            }
            result.append(WeeklyEarningPoint(
                id: WeekMath.dayKey(for: weekStart),
                weekStart: weekStart,
                label: label,
                amount: amountPennies
            ))
        }
        return result
    }

    /// Cached gem total for a hero; nil when no rows so callers can fall back to the service read.
    static func cachedGemTotal(ledgers: [GemLedgerCache], profileName: String) -> Int? {
        let matching = ledgers.filter { $0.profileRecordName == profileName }
        guard !matching.isEmpty else { return nil }
        return matching.reduce(0) { $0 + $1.amount }
    }
}
