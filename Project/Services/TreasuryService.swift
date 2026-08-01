//
//  TreasuryService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

@MainActor
@Observable
final class TreasuryService {
    private let cloudKit: CloudKitService
    let notificationService: NotificationService?
    var cacheService: CacheService?

    var toastManager: ToastManager?

    init(cloudKit: CloudKitService, notificationService: NotificationService? = nil, cacheService: CacheService? = nil) {
        self.cloudKit = cloudKit
        self.notificationService = notificationService
        self.cacheService = cacheService
    }

    func currentBalance(for profile: Profile) async throws -> Double {
        let earnings = try await goldFromQuests(profile: profile)
        let ledgerEntries = try await fetchAllLedgerEntries(profile: profile)
        let bonusGold = ledgerEntries
            .filter { $0.amount > 0 }
            .reduce(0.0) { $0 + $1.amount }
        let spending = ledgerEntries
            .filter { $0.amount < 0 }
            .reduce(0.0) { $0 + $1.amount }
        return earnings + bonusGold + spending
    }

    struct WeeklyBreakdown: Equatable, Sendable {
        var questsCount: Int = 0

        var goldFromQuests: Double = 0

        var bonusGold: Double = 0

        var totalEarned: Double = 0

        var spent: Double = 0

        var net: Double = 0

        var payoutStatus: PayoutStatus?
        var paidAmount: Double?
    }

    func weeklyBreakdown(profile: Profile,
                         weekOf: Date) async throws -> WeeklyBreakdown
    {
        let monday = TreasuryService.mondayOfWeek(for: weekOf)
        let weekRange = TreasuryService.weekRange(starting: monday)

        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: monday,
                                            weekEnding: weekRange.upperBound)
        var goldFromQuests = try await sumGold(for: logs)
        let completedCount = logs.filter { TreasuryService.isCompleted($0) }.count

        // Check if hero has strict All-or-Nothing payout policy enabled.
        if profile.payoutPolicy == .allOrNothing {
            let assigned = try await fetchAssignedQuests(profile: profile, weekOf: monday)
            if !assigned.isEmpty, completedCount < assigned.count {
                goldFromQuests = 0.0
            }
        }

        let ledgerEntries = try await fetchLedgerEntries(
            profile: profile, in: weekRange
        )
        let bonusGold = ledgerEntries
            .filter { $0.amount > 0 }
            .reduce(0.0) { $0 + $1.amount }
        let spent = ledgerEntries
            .filter { $0.amount < 0 }
            .reduce(0.0) { $0 + $1.amount }

        let totalEarned = goldFromQuests + bonusGold
        return WeeklyBreakdown(
            questsCount: completedCount,
            goldFromQuests: goldFromQuests,
            bonusGold: bonusGold,
            totalEarned: totalEarned,
            spent: spent,
            net: totalEarned + spent
        )
    }

    func getOrCreateAllowancePeriod(profile: Profile,
                                    weekOf: Date,
                                    family: Family) async throws -> AllowancePeriod
    {
        let monday = TreasuryService.mondayOfWeek(for: weekOf)
        let existing = try await fetchAllowancePeriod(profile: profile,
                                                      weekOf: monday)
        if let existing {
            return existing
        }

        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: monday,
                                            weekEnding: TreasuryService
                                                .weekRange(starting: monday).upperBound)
        let completedCount = logs.filter { TreasuryService.isCompleted($0) }.count

        let period = AllowancePeriod(
            weekOf: monday,
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            questsTotal: completedCount,
            family: CKRecord.Reference(recordID: family.id, action: .none)
        )

        cacheService?.upsertAllowancePeriod(period)
        // Brand-new record: there is no prior cache snapshot, so
        // `preMutationChangeTag` is `nil` and the changeTag-divergence check
        // below is effectively a no-op (returns `false`). The guard is
        // applied for consistency with the other TreasuryService update paths.
        let preMutationChangeTag: String? = nil
        do {
            let saved = try await cloudKit.save(period)
            cacheService?.upsertAllowancePeriod(saved)
            return saved
        } catch {
            let concurrentEditDetected = ConcurrentEditDetector.detectConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { cacheService?.fetchAllowancePeriods(family: period.family.recordID.recordName)
                    .first(where: { $0.recordName == period.id.recordName })?.changeTag
                },
                error: error
            )

            if concurrentEditDetected {
                // Concurrent edit: the server has a newer record. Discard our optimistic
                // write by re-fetching the authoritative server record, OR invalidate
                // if the re-fetch also fails (no snapshot to restore for new records).
                toastManager?.show(
                    message: "Data was modified by another device. Refresh to see the latest.",
                    type: .warning
                )

                if let fresh = try? await cloudKit.fetch(AllowancePeriod.self, id: period.id) {
                    cacheService?.upsertAllowancePeriod(fresh)
                } else {
                    cacheService?.invalidateAllowancePeriod(recordName: period.id.recordName)
                }
            } else {
                cacheService?.invalidateAllowancePeriod(recordName: period.id.recordName)
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                toastManager?.show(message: message, type: .error)
            }
            throw error
        }
    }

    func updateAllowance(period: AllowancePeriod,
                         totalEarned: Double? = nil,
                         questsCompleted: Int? = nil,
                         questsTotal: Int? = nil) async throws -> AllowancePeriod
    {
        var updated = period

        if let profile = try? await cloudKit.fetch(Profile.self, id: period.profile.recordID) {
            let breakdown = try await weeklyBreakdown(profile: profile,
                                                      weekOf: period.weekOf)
            updated.totalEarned = totalEarned ?? breakdown.totalEarned
            updated.questsCompleted = questsCompleted ?? breakdown.questsCount
        } else {
            if let totalEarned {
                updated.totalEarned = totalEarned
            }
            if let questsCompleted {
                updated.questsCompleted = questsCompleted
            }
        }
        if let questsTotal {
            updated.questsTotal = questsTotal
        }

        let name = period.id.recordName
        let snapshot = cacheService?.fetchAllowancePeriods(family: period.family.recordID.recordName).first(where: { $0.recordName == name })

        // Capture the last-seen server changeTag BEFORE the optimistic write so
        // we can detect a concurrent edit from another device (or background
        let preMutationChangeTag = snapshot?.changeTag

        // Capture an immutable value-type copy of the snapshot BEFORE the
        // optimistic write. The cache-managed `snapshot` will be mutated in
        // place by `upsertAllowancePeriod`, so reading
        // `snapshot.toAllowancePeriod(...)` later would yield the
        // *post*-mutation values. The value-type copy
        // (`AllowancePeriod` struct) is unaffected by later mutations.
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        let snapshotPeriod: AllowancePeriod? = snapshot?.toAllowancePeriod(zoneID: cloudKit.resolvedZoneID)

        cacheService?.upsertAllowancePeriod(updated)
        do {
            let saved = try await cloudKit.save(updated)
            cacheService?.upsertAllowancePeriod(saved)
            return saved
        } catch {
            let concurrentEditDetected = ConcurrentEditDetector.detectConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { cacheService?.fetchAllowancePeriods(family: period.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                error: error
            )

            if concurrentEditDetected {
                // Concurrent edit: the server has a newer record. Discard our optimistic
                // write by re-fetching the authoritative server record, OR fall back to
                // the pre-mutation snapshot if the re-fetch also fails.
                toastManager?.show(
                    message: "Data was modified by another device. Refresh to see the latest.",
                    type: .warning
                )

                if let fresh = try? await cloudKit.fetch(AllowancePeriod.self, id: period.id) {
                    cacheService?.upsertAllowancePeriod(fresh)
                } else if let snapshotPeriod {
                    cacheService?.upsertAllowancePeriod(snapshotPeriod)
                }
            } else {
                if let snapshotPeriod {
                    cacheService?.upsertAllowancePeriod(snapshotPeriod)
                }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                toastManager?.show(message: message, type: .error)
            }
            throw error
        }
    }

    func runPayout(period: AllowancePeriod) async throws {
        var updated = period
        updated.status = .paid
        updated.paidDate = Date()
        updated.paidAmount = updated.totalEarned

        let name = period.id.recordName
        let snapshot = cacheService?.fetchAllowancePeriods(family: period.family.recordID.recordName).first(where: { $0.recordName == name })

        // Capture the last-seen server changeTag BEFORE the optimistic write so
        // we can detect a concurrent edit from another device (or background
        let preMutationChangeTag = snapshot?.changeTag

        // Capture an immutable value-type copy of the snapshot BEFORE the
        // optimistic write. The cache-managed `snapshot` will be mutated in
        // place by `upsertAllowancePeriod`, so reading
        // `snapshot.toAllowancePeriod(...)` later would yield the
        // *post*-mutation values. The value-type copy
        // (`AllowancePeriod` struct) is unaffected by later mutations.
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        let snapshotPeriod: AllowancePeriod? = snapshot?.toAllowancePeriod(zoneID: cloudKit.resolvedZoneID)

        // Optimistic write first
        cacheService?.upsertAllowancePeriod(updated)

        do {
            let saved = try await cloudKit.save(updated)
            cacheService?.upsertAllowancePeriod(saved)

            if let notificationService {
                Task {
                    if let profile = try? await cloudKit.fetch(Profile.self, id: period.profile.recordID),
                       let family = try? await cloudKit.fetch(Family.self, id: period.family.recordID)
                    {
                        try? await notificationService.sendWeeklySummary(to: profile, family: family, weekOf: period.weekOf)
                    }
                }
            }
        } catch {
            let concurrentEditDetected = ConcurrentEditDetector.detectConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { cacheService?.fetchAllowancePeriods(family: period.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                error: error
            )

            if concurrentEditDetected {
                // Concurrent edit: the server has a newer record. Discard our optimistic
                // write by re-fetching the authoritative server record, OR fall back to
                // the pre-mutation snapshot if the re-fetch also fails.
                toastManager?.show(
                    message: "Data was modified by another device. Refresh to see the latest.",
                    type: .warning
                )

                if let fresh = try? await cloudKit.fetch(AllowancePeriod.self, id: period.id) {
                    cacheService?.upsertAllowancePeriod(fresh)
                } else if let snapshotPeriod {
                    cacheService?.upsertAllowancePeriod(snapshotPeriod)
                }
            } else {
                if let snapshotPeriod {
                    cacheService?.upsertAllowancePeriod(snapshotPeriod)
                }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                toastManager?.show(message: message, type: .error)
            }
            throw error
        }
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    private func goldFromQuests(profile: Profile) async throws -> Double {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let cachedCompletions = cache.fetchQuestCompletions(family: profile.family.recordID.recordName)
                .filter { $0.completerRecordName == profileName }
            if !cachedCompletions.isEmpty {
                let zoneID = cloudKit.resolvedZoneID
                let logs = cachedCompletions.map { $0.toQuestCompletion(zoneID: zoneID) }
                return try await sumGold(for: logs)
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "completedBy == %@", profileRef as CVarArg)
        let logs = try await cloudKit.query(QuestCompletion.self, predicate: predicate)
        cacheService?.upsertQuestCompletions(logs)
        return try await sumGold(for: logs)
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    private func fetchAllLedgerEntries(profile: Profile) async throws -> [LedgerEntry] {
        // Cache-first
        if let cache = cacheService {
            let cached = cache.fetchLedgerEntries(
                profileRecordName: profile.id.recordName,
                family: profile.family.recordID.recordName
            )
            if !cached.isEmpty {
                return cached.map { $0.toLedgerEntry(zoneID: cloudKit.resolvedZoneID) }
            }
        }
        // Fallback to CloudKit
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "profile == %@",
                                    profileRef as CVarArg)
        let entries = try await cloudKit.query(LedgerEntry.self, predicate: predicate)
        cacheService?.upsertLedgerEntries(entries)
        return entries
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    func fetchAllowancePeriods(family: Family) async -> [AllowancePeriod] {
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)

        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchAllowancePeriods(family: familyName)
            if !cached.isEmpty {
                let zoneID = cloudKit.resolvedZoneID
                return cached.map { $0.toAllowancePeriod(zoneID: zoneID) }
            }
        }

        // Fallback to CloudKit — preserve the original sort: newest week first.
        let all = await (try? cloudKit.query(
            AllowancePeriod.self,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "weekOf", ascending: false)]
        )) ?? []
        cacheService?.upsertAllowancePeriods(all)
        return all
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    private func fetchLedgerEntries(profile: Profile,
                                    in dateRange: Range<Date>) async throws -> [LedgerEntry]
    {
        if let cache = cacheService {
            let cached = cache.fetchLedgerEntries(
                profileRecordName: profile.id.recordName,
                family: profile.family.recordID.recordName
            )
            let filtered = cached.filter { dateRange.contains($0.date) }
            if !filtered.isEmpty {
                return filtered.map { $0.toLedgerEntry(zoneID: cloudKit.resolvedZoneID) }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(
            format: "profile == %@ AND date >= %@ AND date < %@",
            profileRef as CVarArg,
            dateRange.lowerBound as CVarArg,
            dateRange.upperBound as CVarArg
        )
        let entries = try await cloudKit.query(LedgerEntry.self, predicate: predicate)
        cacheService?.upsertLedgerEntries(entries)
        return entries
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    private func fetchQuestLogs(profile: Profile,
                                weekStarting: Date,
                                weekEnding: Date) async throws -> [QuestCompletion]
    {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let cached = cache.fetchQuestCompletions(family: profile.family.recordID.recordName)
                .filter { $0.completerRecordName == profileName && $0.weekOf >= weekStarting && $0.weekOf < weekEnding }
            if !cached.isEmpty {
                let zoneID = cloudKit.resolvedZoneID
                return cached.map { $0.toQuestCompletion(zoneID: zoneID) }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "completedBy == %@", profileRef as CVarArg)
        let all = try await cloudKit.query(QuestCompletion.self, predicate: predicate)
        cacheService?.upsertQuestCompletions(all)
        return all.filter { $0.weekOf >= weekStarting && $0.weekOf < weekEnding }
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    private func fetchAssignedQuests(profile: Profile, weekOf: Date) async throws -> [Quest] {
        let range = TreasuryService.weekRange(starting: TreasuryService.mondayOfWeek(for: weekOf))

        if let cache = cacheService {
            let profileName = profile.id.recordName
            let cached = cache.fetchQuests(family: profile.family.recordID.recordName)
                .filter { $0.assigneeRecordName == profileName && range.contains($0.weekOf) }
            if !cached.isEmpty {
                let zoneID = cloudKit.resolvedZoneID
                return cached.map { $0.toQuest(zoneID: zoneID) }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "assignee == %@", profileRef as CVarArg)
        let all = try await cloudKit.query(Quest.self, predicate: predicate)
        cacheService?.upsertQuests(all)
        return all.filter { range.contains($0.weekOf) }
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    private func fetchAllowancePeriod(profile: Profile,
                                      weekOf: Date) async throws -> AllowancePeriod?
    {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let cached = cache.fetchAllowancePeriods(profileRecordName: profileName, family: profile.family.recordID.recordName)
                .first { Calendar.iso8601UTC.isDate($0.weekOf, inSameDayAs: weekOf) }
            if let cached {
                return cached.toAllowancePeriod(zoneID: cloudKit.resolvedZoneID)
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(
            format: "profile == %@ AND weekOf == %@",
            profileRef as CVarArg,
            weekOf as CVarArg
        )
        let periods = try await cloudKit.query(AllowancePeriod.self,
                                               predicate: predicate)
        cacheService?.upsertAllowancePeriods(periods)
        return periods.first
    }

    private func sumGold(for logs: [QuestCompletion]) async throws -> Double {
        var completedLogs: [QuestCompletion] = []
        completedLogs.reserveCapacity(logs.count)
        for log in logs where TreasuryService.isCompleted(log) {
            completedLogs.append(log)
        }
        guard !completedLogs.isEmpty else { return 0 }

        let uniqueQuestIDs = Array(Set(completedLogs.map(\.quest.recordID)))
        var questCache: [CKRecord.ID: Quest] = [:]

        // Cache-first: build a lookup dictionary from the family's cached
        // quests.  Only quest IDs absent from the cache fall through to the
        // chunked CloudKit fetch below (genuine cache miss — e.g. very first
        if let cache = cacheService,
           let familyName = completedLogs.first?.family.recordID.recordName
        {
            let zoneID = cloudKit.resolvedZoneID
            for row in cache.fetchQuests(family: familyName) {
                let quest = row.toQuest(zoneID: zoneID)
                questCache[quest.id] = quest
            }
        }

        let missingIDs = uniqueQuestIDs.filter { questCache[$0] == nil }

        // CK fallback ONLY for cache-miss IDs.
        if !missingIDs.isEmpty {
            for chunk in missingIDs.chunked(into: 100) {
                let predicate = NSPredicate(format: "recordID IN %@", chunk)
                do {
                    let fetched: [Quest] = try await cloudKit.query(Quest.self, predicate: predicate)
                    for quest in fetched {
                        questCache[quest.id] = quest
                    }
                } catch {
                    for questID in chunk {
                        if let fetched = try? await cloudKit.fetch(Quest.self, id: questID) {
                            questCache[questID] = fetched
                        }
                    }
                }
            }
        }

        // Group approved logs by quest so the shared proration helper is
        // invoked once per quest with the full approved count — paying the
        // prorated bounty (all-or-nothing or per-unit) rather than the full
        // goldReward on every single log.
        var approvedCountByQuest: [CKRecord.ID: Int] = [:]
        for log in completedLogs {
            approvedCountByQuest[log.quest.recordID, default: 0] += 1
        }

        var totalGold: Double = 0
        for (questID, approvedCount) in approvedCountByQuest {
            if let quest = questCache[questID] {
                totalGold += GoldCalculation.creditAsDouble(for: quest,
                                                            approvedCount: approvedCount)
            }
        }
        return totalGold
    }

    private static func isCompleted(_ log: QuestCompletion) -> Bool {
        log.verificationStatus == .verified
            || log.verificationStatus == .autoApproved
    }

    static func weekRange(starting monday: Date) -> Range<Date> {
        WeekMath.weekRange(starting: monday)
    }

    static func mondayOfWeek(for date: Date) -> Date {
        WeekMath.mondayOfWeek(for: date)
    }
}
