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
        let slainCount = logs.filter { TreasuryService.isSlain($0) }.count

        // Check if hero has strict All-or-Nothing payout policy enabled.
        if profile.payoutPolicy == .allOrNothing {
            let assigned = try await fetchAssignedQuests(profile: profile, weekOf: monday)
            if !assigned.isEmpty, slainCount < assigned.count {
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
            questsCount: slainCount,
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
        let slainCount = logs.filter { TreasuryService.isSlain($0) }.count

        let period = AllowancePeriod(
            weekOf: monday,
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            questsTotal: slainCount,
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
            let concurrentEditDetected = TreasuryService.detectConcurrentEdit(
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
        // sync) while the save is in flight.
        let preMutationChangeTag = snapshot?.changeTag

        cacheService?.upsertAllowancePeriod(updated)
        do {
            let saved = try await cloudKit.save(updated)
            cacheService?.upsertAllowancePeriod(saved)
            return saved
        } catch {
            let concurrentEditDetected = TreasuryService.detectConcurrentEdit(
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
                } else if let snapshot {
                    cacheService?.upsertAllowancePeriod(snapshot.toAllowancePeriod(zoneID: cloudKit.resolvedZoneID))
                }
            } else {
                if let snapshot {
                    cacheService?.upsertAllowancePeriod(snapshot.toAllowancePeriod(zoneID: cloudKit.resolvedZoneID))
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
        // sync) while the save is in flight.
        let preMutationChangeTag = snapshot?.changeTag

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
            let concurrentEditDetected = TreasuryService.detectConcurrentEdit(
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
                } else if let snapshot {
                    cacheService?.upsertAllowancePeriod(snapshot.toAllowancePeriod(zoneID: cloudKit.resolvedZoneID))
                }
            } else {
                if let snapshot {
                    cacheService?.upsertAllowancePeriod(snapshot.toAllowancePeriod(zoneID: cloudKit.resolvedZoneID))
                }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                toastManager?.show(message: message, type: .error)
            }
            throw error
        }
    }

    private func goldFromQuests(profile: Profile) async throws -> Double {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let cachedCompletions = cache.fetchQuestCompletions(family: profile.family.recordID.recordName)
                .filter { $0.completerRecordName == profileName }
            if !cachedCompletions.isEmpty {
                let zoneID = cloudKit.resolvedZoneID
                let logs = cachedCompletions.map { $0.toQuestCompletion(zoneID: zoneID) }
                Task { [cloudKit, cacheService] in
                    let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                    let predicate = NSPredicate(format: "completedBy == %@", profileRef as CVarArg)
                    if let fresh = try? await cloudKit.query(QuestCompletion.self, predicate: predicate) {
                        cacheService?.upsertQuestCompletions(fresh)
                    }
                }
                return try await sumGold(for: logs)
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "completedBy == %@", profileRef as CVarArg)
        let logs = try await cloudKit.query(QuestCompletion.self, predicate: predicate)
        cacheService?.upsertQuestCompletions(logs)
        return try await sumGold(for: logs)
    }

    private func fetchAllLedgerEntries(profile: Profile) async throws -> [LedgerEntry] {
        // Cache-first
        if let cache = cacheService {
            let cached = cache.fetchLedgerEntries(profileRecordName: profile.id.recordName)
            if !cached.isEmpty {
                // Background refresh
                Task { [cloudKit, cacheService] in
                    let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                    let predicate = NSPredicate(format: "profile == %@", profileRef as CVarArg)
                    if let fresh = try? await cloudKit.query(LedgerEntry.self, predicate: predicate) {
                        cacheService?.upsertLedgerEntries(fresh)
                    }
                }
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

    func fetchAllowancePeriods(family: Family) async -> [AllowancePeriod] {
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)

        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchAllowancePeriods(family: familyName)
            if !cached.isEmpty {
                // Background refresh keeps the cache honest across silent pushes.
                Task { [cloudKit, cacheService] in
                    if let fresh = try? await cloudKit.query(
                        AllowancePeriod.self,
                        predicate: predicate,
                        sortDescriptors: [NSSortDescriptor(key: "weekOf", ascending: false)]
                    ) {
                        cacheService?.upsertAllowancePeriods(fresh)
                    }
                }
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

    private func fetchLedgerEntries(profile: Profile,
                                    in dateRange: Range<Date>) async throws -> [LedgerEntry]
    {
        if let cache = cacheService {
            let cached = cache.fetchLedgerEntries(profileRecordName: profile.id.recordName)
            let filtered = cached.filter { dateRange.contains($0.date) }
            if !filtered.isEmpty {
                Task { [cloudKit, cacheService] in
                    let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                    let predicate = NSPredicate(
                        format: "profile == %@ AND date >= %@ AND date < %@",
                        profileRef as CVarArg,
                        dateRange.lowerBound as CVarArg,
                        dateRange.upperBound as CVarArg
                    )
                    if let fresh = try? await cloudKit.query(LedgerEntry.self, predicate: predicate) {
                        cacheService?.upsertLedgerEntries(fresh)
                    }
                }
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

    private func fetchQuestLogs(profile: Profile,
                                weekStarting: Date,
                                weekEnding: Date) async throws -> [QuestCompletion]
    {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let cached = cache.fetchQuestCompletions(family: profile.family.recordID.recordName)
                .filter { $0.completerRecordName == profileName && $0.weekOf >= weekStarting && $0.weekOf < weekEnding }
            if !cached.isEmpty {
                Task { [cloudKit, cacheService] in
                    let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                    let predicate = NSPredicate(format: "completedBy == %@", profileRef as CVarArg)
                    if let fresh = try? await cloudKit.query(QuestCompletion.self, predicate: predicate) {
                        cacheService?.upsertQuestCompletions(fresh)
                    }
                }
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

    private func fetchAssignedQuests(profile: Profile, weekOf: Date) async throws -> [Quest] {
        let range = TreasuryService.weekRange(starting: TreasuryService.mondayOfWeek(for: weekOf))

        if let cache = cacheService {
            let profileName = profile.id.recordName
            let cached = cache.fetchQuests(family: profile.family.recordID.recordName)
                .filter { $0.assigneeRecordName == profileName && range.contains($0.weekOf) }
            if !cached.isEmpty {
                Task { [cloudKit, cacheService] in
                    let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                    let predicate = NSPredicate(format: "assignee == %@", profileRef as CVarArg)
                    if let fresh = try? await cloudKit.query(Quest.self, predicate: predicate) {
                        cacheService?.upsertQuests(fresh)
                    }
                }
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

    private func fetchAllowancePeriod(profile: Profile,
                                      weekOf: Date) async throws -> AllowancePeriod?
    {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let cached = cache.fetchAllowancePeriods(profileRecordName: profileName)
                .first { Calendar.iso8601UTC.isDate($0.weekOf, inSameDayAs: weekOf) }
            if let cached {
                Task { [cloudKit, cacheService] in
                    let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                    let predicate = NSPredicate(
                        format: "profile == %@ AND weekOf == %@",
                        profileRef as CVarArg,
                        weekOf as CVarArg
                    )
                    if let fresh = try? await cloudKit.query(AllowancePeriod.self, predicate: predicate).first {
                        cacheService?.upsertAllowancePeriod(fresh)
                    }
                }
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
        var slainLogs: [QuestCompletion] = []
        slainLogs.reserveCapacity(logs.count)
        for log in logs where TreasuryService.isSlain(log) {
            slainLogs.append(log)
        }
        guard !slainLogs.isEmpty else { return 0 }

        let uniqueQuestIDs = Array(Set(slainLogs.map(\.quest.recordID)))
        var questCache: [CKRecord.ID: Quest] = [:]

        // Cache-first: build a lookup dictionary from the family's cached
        // quests.  Only quest IDs absent from the cache fall through to the
        // chunked CloudKit fetch below (genuine cache miss — e.g. very first
        // launch before syncAll completes).
        if let cache = cacheService,
           let familyName = slainLogs.first?.family.recordID.recordName
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

        var totalGold: Double = 0
        for log in slainLogs {
            if let quest = questCache[log.quest.recordID] {
                totalGold += quest.goldReward
            }
        }
        return totalGold
    }

    private static func isSlain(_ log: QuestCompletion) -> Bool {
        log.verificationStatus == .verified
            || log.verificationStatus == .autoApproved
    }

    /// Detects whether another device (or this device's background sync) has
    /// applied a conflicting mutation while the in-flight save was failing.
    ///
    /// Two independent signals are checked; either one is sufficient evidence of
    /// a concurrent edit:
    ///   1) CloudKit raised a `serverRecordChanged` error during `cloudKit.save`.
    ///      CloudKitService wraps raw `CKError` instances into
    ///      `CloudKitServiceError` before throwing, so we pattern-match the
    ///      wrapped form — `CloudKitServiceError.notFound("serverRecordChanged")`
    ///      — rather than `CKError` itself, which the service layer never sees.
    ///   2) The cache row's current `changeTag` differs from the
    ///      `preMutationChangeTag` we captured before the optimistic write. A
    ///      background sync may have pulled Mutation B's update into the cache
    ///      during the `await cloudKit.save(...)` call, mutating the cached row's
    ///      changeTag. When both sides are present and unequal, we conclude a
    ///      concurrent edit landed.
    ///
    /// When neither signal is present (the common case — including, by design,
    /// brand-new records, where `preMutationChangeTag == nil` because there was
    /// no prior cache row to snapshot), this returns `false` and the caller
    /// proceeds with the standard rollback.
    static func detectConcurrentEdit(
        preMutationChangeTag: String?,
        fetchCurrent: () -> String?,
        error: Error
    ) -> Bool {
        // Signal 1: CloudKit's canonical optimistic-concurrency conflict.
        if case let .notFound(details) = error as? CloudKitServiceError,
           details == "serverRecordChanged"
        {
            return true
        }

        // Signal 2: changeTag divergence detected via a cache re-fetch.
        let currentChangeTag = fetchCurrent()
        return {
            guard let pre = preMutationChangeTag,
                  let cur = currentChangeTag,
                  !cur.isEmpty
            else { return false }
            return pre != cur
        }()
    }

    static func weekRange(starting monday: Date) -> Range<Date> {
        WeekMath.weekRange(starting: monday)
    }

    static func mondayOfWeek(for date: Date) -> Date {
        WeekMath.mondayOfWeek(for: date)
    }
}
