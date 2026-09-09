//
//  CacheService+Fetches.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import os
import SwiftData

@MainActor
extension CacheService {
    private static let fetchLogger = Logger(category: "CacheService")

    // MARK: - Family scope guard (DRY)

    /// Shared fail-closed guard for every family-scoped fetch. Returns the
    /// unwrapped family when non-empty, otherwise logs and returns nil so
    /// callers can `guard let family = guardFamily(family) else { return [] }`.
    private func guardFamily(_ family: String?) -> String? {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("family-scoped fetch called without family scope — returning empty (fail-closed)")
            return nil
        }
        return family
    }

    // MARK: - Generic helper

    /// Fetch helper accepting a pre-configured FetchDescriptor.
    func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> [T] {
        guard let context else { return [] }
        do {
            return try context.fetch(descriptor)
        } catch {
            Self.fetchLogger.error("Failed to fetch \(String(describing: T.self), privacy: .private): \(error, privacy: .private)")
            return []
        }
    }

    /// Generic fetch helper that handles the common fetch pattern.
    func fetch<T: PersistentModel>(
        _: T.Type,
        predicate: Predicate<T>? = nil,
        sortBy: [SortDescriptor<T>] = []
    ) -> [T] {
        fetch(FetchDescriptor<T>(predicate: predicate, sortBy: sortBy))
    }

    /// Fail-closed variant of `fetch`: returns `nil` when the cache context is unavailable or the
    /// underlying fetch throws, instead of collapsing the failure into an empty array.
    func tryFetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> [T]? {
        guard let context else { return nil }
        do {
            return try context.fetch(descriptor)
        } catch {
            Self.fetchLogger.error("Failed to fetch \(String(describing: T.self), privacy: .private): \(error, privacy: .private)")
            return nil
        }
    }

    /// Generic FamilyScoped fetch helper — single predicate source for every
    /// family-scoped cache read. Reduces per-type boilerplate; future cached
    /// types get fetch for free by conforming to ``FamilyScopedFetchable``.
    func fetchAll<T: FamilyScopedFetchable>(_: T.Type, family: String) -> [T] {
        guard let family = guardFamily(family) else { return [] }
        return fetch(T.fetchDescriptor(familyRecordName: family))
    }

    /// Sorted overload for call sites that require deterministic ordering.
    func fetchAll<T: FamilyScopedFetchable>(_: T.Type, family: String, sortBy: [SortDescriptor<T>]) -> [T] {
        guard let family = guardFamily(family) else { return [] }
        var descriptor = T.fetchDescriptor(familyRecordName: family)
        descriptor.sortBy = sortBy
        return fetch(descriptor)
    }

    // MARK: - Public fetch API

    /// Fetches quests, optionally filtered by family and/or a week range.
    func fetchQuests(family: String?, weekInRange: Range<Date>?) -> [QuestCache] {
        guard let family = guardFamily(family) else { return [] }
        if let range = weekInRange {
            let start = range.lowerBound
            let end = range.upperBound
            return fetch(
                QuestCache.self,
                predicate: #Predicate { item in
                    item.familyRecordName == family
                        && item.weekOf >= start
                        && item.weekOf < end
                }
            )
        }
        return fetchAll(QuestCache.self, family: family)
    }

    /// Protocol witness for `CacheServicing.fetchQuests(family:)` – forwards to the ranged fetch with nil range.
    func fetchQuests(family: String?) -> [QuestCache] {
        fetchQuests(family: family, weekInRange: nil)
    }

    func fetchQuest(recordName: String, family: String) -> QuestCache? {
        fetch(QuestCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchQuestCompletions(family: String?) -> [QuestCompletionCache] {
        guard let family = guardFamily(family) else { return [] }
        return fetchAll(QuestCompletionCache.self, family: family)
    }

    func fetchQuestCompletion(recordName: String, family: String) -> QuestCompletionCache? {
        fetch(QuestCompletionCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchProfile(recordName: String, family: String) -> ProfileCache? {
        fetch(ProfileCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchProfiles(family: String?) -> [ProfileCache] {
        guard let family = guardFamily(family) else { return [] }
        return fetchAll(ProfileCache.self, family: family)
    }

    func fetchQuestTemplates(family: String?) -> [QuestTemplateCache] {
        guard let family = guardFamily(family) else { return [] }
        return fetchAll(QuestTemplateCache.self, family: family)
    }

    func fetchQuestTemplate(recordName: String, family: String) -> QuestTemplateCache? {
        fetch(QuestTemplateCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchFamily(recordName: String) -> FamilyCache? {
        fetch(FamilyCache.self, predicate: #Predicate { $0.recordName == recordName }).first
    }

    func fetchFamily(identity: ScopedRecordIdentity) -> FamilyCache? {
        fetchFamily(recordName: identity.recordID.recordName)
    }

    func fetchLedgerEntry(recordName: String, family: String) -> LedgerEntryCache? {
        fetch(LedgerEntryCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchAllowancePeriod(recordName: String, family: String) -> AllowancePeriodCache? {
        fetch(AllowancePeriodCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchAchievement(recordName: String, family: String) -> AchievementCache? {
        fetch(AchievementCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchProfileAchievement(recordName: String, family: String) -> ProfileAchievementCache? {
        fetch(ProfileAchievementCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchNotificationPreference(recordName: String, family: String) -> NotificationPreferenceCache? {
        fetch(NotificationPreferenceCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchLedgerEntries(profileRecordName: String, family: String? = nil) -> [LedgerEntryCache] {
        #if DEBUG
            ledgerEntryFetchScopes.append(family)
        #endif
        guard let family = guardFamily(family) else { return [] }
        return fetch(
            LedgerEntryCache.self,
            predicate: #Predicate { $0.profileRecordName == profileRecordName && $0.familyRecordName == family },
            // WHY secondary recordName: same-date rows stay stably ordered with every @Query ledger sort.
            sortBy: [SortDescriptor(\.date, order: .reverse), SortDescriptor(\LedgerEntryCache.recordName)]
        )
    }

    /// WHY indexed window: family+profile+date rides the V10 composite index so history never scans.
    /// WARNING: Do not add fromBucket/toBucket to DB predicate — sparse optionals not indexed, would force table scan.
    /// WHY secondary recordName: same-date rows stay stably ordered with every @Query ledger sort.
    func fetchLedgerEntries(profileRecordName: String, familyRecordName: String, start: Date, end: Date) -> [LedgerEntryCache] {
        guard !familyRecordName.isEmpty, !profileRecordName.isEmpty else {
            Self.fetchLogger.warning("fetchLedgerEntries(dateRange) called without family/profile scope — returning empty (fail-closed)")
            return []
        }
        guard start < end else { return [] }
        return fetch(
            LedgerEntryCache.self,
            predicate: #Predicate { entry in
                entry.profileRecordName == profileRecordName
                    && entry.familyRecordName == familyRecordName
                    && entry.date >= start
                    && entry.date < end
            },
            sortBy: [SortDescriptor(\.date, order: .reverse), SortDescriptor(\LedgerEntryCache.recordName)]
        )
    }

    /// WHY DB-level predicate narrows via composite index
    /// `[\.familyRecordName, \.profileRecordName, \.source, \.date]` to the
    /// (family, profile, source, date) subset; `fromBucket`/`toBucket` are
    /// sparse optionals not indexed and are filtered in-memory on the small
    /// indexed subset, avoiding O(n) main-thread scans and table scans.
    /// WARNING: Do not add fromBucket/toBucket to DB predicate — sparse optionals not indexed, would force table scan.
    func fetchTransfers(
        profileRecordName: String,
        familyRecordName: String,
        from fromRaw: String,
        to toRaw: String,
        dayBucket: Int
    ) -> [LedgerEntryCache] {
        guard !familyRecordName.isEmpty, !profileRecordName.isEmpty else {
            Self.fetchLogger.warning("fetchTransfers called without family/profile scope — returning empty (fail-closed)")
            return []
        }
        guard !fromRaw.isEmpty, !toRaw.isEmpty else { return [] }
        let range = WeekMath.utcDateRange(forDayBucket: dayBucket)
        let todayStart = range.lowerBound
        let todayEnd = range.upperBound
        let transferSource = LedgerSource.transfer.rawValue
        let candidates = fetch(
            LedgerEntryCache.self,
            predicate: #Predicate { entry in
                entry.profileRecordName == profileRecordName
                    && entry.familyRecordName == familyRecordName
                    && entry.source == transferSource
                    && entry.date >= todayStart
                    && entry.date < todayEnd
            }
        )
        // Sparse optional pair not indexed — refine small indexed subset in-memory.
        return candidates.filter { $0.fromBucket == fromRaw && $0.toBucket == toRaw }
    }

    func fetchLedgerEntries(profileRecordName: String, family: String, recordNamePrefix: String) -> [LedgerEntryCache] {
        guard guardFamily(family) != nil else { return [] }
        let prefix = recordNamePrefix
        return fetch(
            LedgerEntryCache.self,
            predicate: #Predicate { $0.profileRecordName == profileRecordName && $0.familyRecordName == family && $0.recordName.starts(with: prefix) }
        )
    }

    func fetchLedgerEntries(family: String?) -> [LedgerEntryCache] {
        guard let family = guardFamily(family) else { return [] }
        return fetchAll(
            LedgerEntryCache.self,
            family: family,
            // WHY secondary recordName: same-date rows stay stably ordered with every @Query ledger sort.
            sortBy: [SortDescriptor(\.date, order: .reverse), SortDescriptor(\LedgerEntryCache.recordName)]
        )
    }

    func fetchAllowancePeriods(profileRecordName: String, family: String? = nil) -> [AllowancePeriodCache] {
        guard let family = guardFamily(family) else { return [] }
        return fetch(
            AllowancePeriodCache.self,
            predicate: #Predicate { $0.profileRecordName == profileRecordName && $0.familyRecordName == family },
            sortBy: [SortDescriptor(\.weekOf, order: .reverse)]
        )
    }

    func fetchAllowancePeriods(family: String?) -> [AllowancePeriodCache] {
        guard let family = guardFamily(family) else { return [] }
        return fetchAll(
            AllowancePeriodCache.self,
            family: family,
            sortBy: [SortDescriptor(\.weekOf, order: .reverse)]
        )
    }

    func fetchAchievements(family: String?) -> [AchievementCache] {
        guard let family = guardFamily(family) else { return [] }
        return fetchAll(AchievementCache.self, family: family)
    }

    func fetchProfileAchievements(profileRecordName: String, family: String? = nil) -> [ProfileAchievementCache] {
        guard let family = guardFamily(family) else { return [] }
        return fetch(
            ProfileAchievementCache.self,
            predicate: #Predicate { $0.profileRecordName == profileRecordName && $0.familyRecordName == family },
            sortBy: [SortDescriptor(\.earnedDate, order: .reverse)]
        )
    }

    func fetchNotificationPreferences(profileRecordName: String, family: String? = nil) -> [NotificationPreferenceCache] {
        guard let family = guardFamily(family) else { return [] }
        return fetch(
            NotificationPreferenceCache.self,
            predicate: #Predicate { $0.profileRecordName == profileRecordName && $0.familyRecordName == family }
        )
    }

    func fetchNotificationPreference(profileRecordName: String, familyRecordName: String, eventType: String) -> NotificationPreferenceCache? {
        fetch(
            NotificationPreferenceCache.self,
            predicate: #Predicate {
                $0.profileRecordName == profileRecordName
                    && $0.familyRecordName == familyRecordName
                    && $0.eventType == eventType
            }
        ).first
    }

    func fetchGemLedgers(family: String?) -> [GemLedgerCache] {
        guard let family = guardFamily(family) else { return [] }
        return fetchAll(GemLedgerCache.self, family: family)
    }

    func fetchGemLedgers(profileRecordName: String, family: String) -> [GemLedgerCache] {
        guard !family.isEmpty else { return [] }
        return fetch(
            GemLedgerCache.self,
            predicate: #Predicate {
                $0.profileRecordName == profileRecordName && $0.familyRecordName == family
            }
        )
    }

    func fetchGemLedger(recordName: String, family: String) -> GemLedgerCache? {
        fetch(GemLedgerCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchRewardEvents(family: String?) -> [RewardEventCache] {
        guard let family = guardFamily(family) else { return [] }
        return fetchAll(RewardEventCache.self, family: family)
    }

    func fetchRewardEvent(recordName: String, family: String) -> RewardEventCache? {
        fetch(RewardEventCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchGoals(family: String?) -> [GoalCache] {
        guard let family = guardFamily(family) else { return [] }
        return fetchAll(GoalCache.self, family: family)
    }

    /// FIFO fill order for a single bucket: oldest incomplete non-archived
    /// goal first, matching the bucket cascade rules.
    func fetchGoals(profileRecordName: String, bucketKind: String, familyRecordName: String) -> [GoalCache] {
        fetch(
            GoalCache.self,
            predicate: #Predicate {
                $0.familyRecordName == familyRecordName
                    && $0.profileRecordName == profileRecordName
                    && $0.bucketKind == bucketKind
            },
            sortBy: [SortDescriptor(\GoalCache.createdAt)]
        )
    }

    func fetchGoal(recordName: String, family: String) -> GoalCache? {
        fetch(GoalCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    /// WHY indexed month: family+profile+date rides the V10 composite index so month history never scans.
    func fetchLedgerEntriesForMonth(profileRecordName: String, familyRecordName: String, month: Date) -> [LedgerEntryCache] {
        let start = WeekMath.monthStart(for: month)
        let end = WeekMath.monthEnd(for: month)
        return fetchLedgerEntries(profileRecordName: profileRecordName, familyRecordName: familyRecordName, start: start, end: end)
    }

    /// WHY family-wide: month history without profile scope rides the family+date index so family totals never scan.
    func fetchLedgerEntriesForMonth(familyRecordName: String, monthContaining: Date, fetchLimit: Int = 200) -> [LedgerEntryCache] {
        guard !familyRecordName.isEmpty else { return [] }
        let start = WeekMath.monthStart(for: monthContaining)
        let end = WeekMath.monthEnd(for: monthContaining)
        var descriptor = FetchDescriptor<LedgerEntryCache>(predicate: #Predicate {
            $0.familyRecordName == familyRecordName && $0.date >= start && $0.date < end
        })
        descriptor.sortBy = [SortDescriptor(\.date, order: .reverse), SortDescriptor(\LedgerEntryCache.recordName)]
        descriptor.fetchLimit = max(1, fetchLimit)
        return fetch(descriptor)
    }

    /// WHY indexed window: recent history rides the V10 date index with a stable sort.
    func fetchRecentLedgerEntries(profileRecordName: String, familyRecordName: String, limit: Int = 50) -> [LedgerEntryCache] {
        guard !familyRecordName.isEmpty, !profileRecordName.isEmpty else { return [] }
        var descriptor = FetchDescriptor<LedgerEntryCache>(predicate: #Predicate {
            $0.profileRecordName == profileRecordName && $0.familyRecordName == familyRecordName
        })
        descriptor.sortBy = [SortDescriptor(\.date, order: .reverse), SortDescriptor(\LedgerEntryCache.recordName)]
        descriptor.fetchLimit = max(1, limit)
        return fetch(descriptor)
    }

    /// WHY family-wide: recent history with optional profile rides the family index so month views never scan.
    func fetchRecentLedgerEntries(familyRecordName: String, profileRecordName: String? = nil, fetchLimit: Int = 50) -> [LedgerEntryCache] {
        guard !familyRecordName.isEmpty else { return [] }
        if let profileRecordName, !profileRecordName.isEmpty {
            return fetchRecentLedgerEntries(profileRecordName: profileRecordName, familyRecordName: familyRecordName, limit: fetchLimit)
        }
        var descriptor = FetchDescriptor<LedgerEntryCache>(predicate: #Predicate {
            $0.familyRecordName == familyRecordName
        })
        descriptor.sortBy = [SortDescriptor(\.date, order: .reverse), SortDescriptor(\LedgerEntryCache.recordName)]
        descriptor.fetchLimit = max(1, fetchLimit)
        return fetch(descriptor)
    }

    /// WHY indexed source: source+date rides the V10 composite index for filtered history.
    func fetchLedgerEntries(profileRecordName: String?, familyRecordName: String, source: String, start: Date, end: Date) -> [LedgerEntryCache] {
        guard !familyRecordName.isEmpty, start < end else { return [] }
        let targetSource = source
        if let profileRecordName, !profileRecordName.isEmpty {
            return fetch(
                LedgerEntryCache.self,
                predicate: #Predicate { entry in
                    entry.profileRecordName == profileRecordName
                        && entry.familyRecordName == familyRecordName
                        && entry.source == targetSource
                        && entry.date >= start
                        && entry.date < end
                },
                sortBy: [SortDescriptor(\.date, order: .reverse), SortDescriptor(\LedgerEntryCache.recordName)]
            )
        }
        return fetch(
            LedgerEntryCache.self,
            predicate: #Predicate { entry in
                entry.familyRecordName == familyRecordName
                    && entry.source == targetSource
                    && entry.date >= start
                    && entry.date < end
            },
            sortBy: [SortDescriptor(\.date, order: .reverse), SortDescriptor(\LedgerEntryCache.recordName)]
        )
    }

    /// WHY indexed source: source+date rides the V10 composite index for filtered history.
    func fetchRecentLedgerEntries(profileRecordName: String, familyRecordName: String, source: String, limit: Int = 50) -> [LedgerEntryCache] {
        guard !familyRecordName.isEmpty, !profileRecordName.isEmpty else { return [] }
        let targetSource = source
        var descriptor = FetchDescriptor<LedgerEntryCache>(predicate: #Predicate {
            $0.profileRecordName == profileRecordName && $0.familyRecordName == familyRecordName && $0.source == targetSource
        })
        descriptor.sortBy = [SortDescriptor(\.date, order: .reverse), SortDescriptor(\LedgerEntryCache.recordName)]
        descriptor.fetchLimit = max(1, limit)
        return fetch(descriptor)
    }

    /// WHY single source: identity overloads keep fetch scoping behind the composite index.
    func fetchQuest(identity: ScopedRecordIdentity) -> QuestCache? {
        guard let family = identity.familyRecordName, !family.isEmpty else { return nil }
        return fetchQuest(recordName: identity.recordName, family: family)
    }

    /// WHY single source: identity overloads keep fetch scoping behind the composite index.
    func fetchProfile(identity: ScopedRecordIdentity) -> ProfileCache? {
        guard let family = identity.familyRecordName, !family.isEmpty else { return nil }
        return fetchProfile(recordName: identity.recordName, family: family)
    }

    /// WHY single source: identity overloads keep fetch scoping behind the composite index.
    func fetchLedgerEntry(identity: ScopedRecordIdentity) -> LedgerEntryCache? {
        guard let family = identity.familyRecordName, !family.isEmpty else { return nil }
        return fetchLedgerEntry(recordName: identity.recordName, family: family)
    }

    /// WHY single source: identity overloads keep fetch scoping behind the composite index.
    func fetchGoal(identity: ScopedRecordIdentity) -> GoalCache? {
        guard let family = identity.familyRecordName, !family.isEmpty else { return nil }
        return fetchGoal(recordName: identity.recordName, family: family)
    }

    /// WHY single source: scoped reads share the guard so isolation never drifts.
    func familyScopedFetch<T: FamilyScopedFetchable>(_: T.Type, family: String) -> [T] {
        fetchAll(T.self, family: family)
    }
}
