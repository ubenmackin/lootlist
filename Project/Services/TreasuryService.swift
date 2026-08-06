//
//  TreasuryService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os

@MainActor
@Observable
final class TreasuryService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "TreasuryService")
    private let cloudKit: any CloudKitServiceProtocol
    let notificationService: NotificationService?
    var cacheService: CacheService?

    /// The active session's app state, used to resolve the acting profile for
    /// privileged payout finalization. Wired by `AppDependencies`; optional so
    /// read-only callers (tests, real-time settlement) need not set it.
    var appState: AppState?

    let toastManager: ToastManager?

    init(
        cloudKit: any CloudKitServiceProtocol,
        notificationService: NotificationService? = nil,
        cacheService: CacheService? = nil,
        toastManager: ToastManager? = nil,
        appState: AppState? = nil
    ) {
        self.cloudKit = cloudKit
        self.notificationService = notificationService
        self.cacheService = cacheService
        self.appState = appState
        self.toastManager = toastManager
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
                         family: Family,
                         weekOf: Date) async throws -> WeeklyBreakdown
    {
        let startOfWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: profile.payoutDay ?? family.payoutDay)
        let weekRange = TreasuryService.weekRange(starting: startOfWeek)

        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: startOfWeek,
                                            weekEnding: weekRange.upperBound)
        var goldFromQuests = try await sumGold(for: logs)
        let completedCount = logs.filter { TreasuryService.isCompleted($0) }.count

        // Check if hero has strict All-or-Nothing payout policy enabled.
        if profile.payoutPolicy == .allOrNothing {
            let assigned = try await fetchAssignedQuests(profile: profile, weekOf: startOfWeek)
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
        // Internal settlement helper: actor must be the target hero (self-settlement)
        // or a parent acting on the hero's behalf.
        guard let acting = appState?.currentProfile,
              acting.id == profile.id || acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }

        let startOfWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: profile.payoutDay ?? family.payoutDay)

        let existing = try await fetchAllowancePeriod(profile: profile,
                                                      weekOf: startOfWeek)
        if let existing {
            return existing
        }

        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: startOfWeek,
                                            weekEnding: TreasuryService
                                                .weekRange(starting: startOfWeek).upperBound)
        let completedCount = logs.filter { TreasuryService.isCompleted($0) }.count

        let period = AllowancePeriod(
            weekOf: startOfWeek,

            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            questsTotal: completedCount,
            family: CKRecord.Reference(recordID: family.id, action: .none)
        )

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(period.id.recordName)

        cacheService?.upsertAllowancePeriod(period)
        // Brand-new record: there is no prior cache snapshot, so
        // `preMutationChangeTag` is `nil` and the changeTag-divergence check
        // below is effectively a no-op (returns `false`). The guard is
        // applied for consistency with the other TreasuryService update paths.
        let preMutationChangeTag: String? = nil
        do {
            let saved = try await cloudKit.save(period)
            cacheService?.upsertAllowancePeriod(saved)
            await registry?.deregister(period.id.recordName)
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
            await registry?.deregister(period.id.recordName)
            throw error
        }
    }

    func updateAllowance(period: AllowancePeriod,
                         totalEarned: Double? = nil,
                         questsCompleted: Int? = nil,
                         questsTotal: Int? = nil) async throws -> AllowancePeriod
    {
        // Internal settlement helper: actor must own the period (hero
        // self-settlement) or be a parent (parent override).
        guard let acting = appState?.currentProfile,
              acting.id == period.profile.recordID || acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }

        var updated = period

        if let profile = try? await cloudKit.fetch(Profile.self, id: period.profile.recordID),
           let family = try? await cloudKit.fetch(Family.self, id: period.family.recordID)
        {
            let breakdown = try await weeklyBreakdown(profile: profile,
                                                      family: family,
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

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertAllowancePeriod(updated)
        do {
            let saved = try await cloudKit.save(updated)
            cacheService?.upsertAllowancePeriod(saved)
            await registry?.deregister(name)
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
            await registry?.deregister(name)
            throw error
        }
    }

    func runPayout(period: AllowancePeriod) async throws {
        // Privileged mutation: finalizing a hero's payout is parent-only.
        guard appState?.currentProfile?.role.isParent == true else {
            throw FamilyServiceError.unauthorized
        }

        var updated = period

        if let profile = try? await cloudKit.fetch(Profile.self, id: period.profile.recordID),
           let family = try? await cloudKit.fetch(Family.self, id: period.family.recordID)
        {
            let breakdown = try await weeklyBreakdown(profile: profile, family: family, weekOf: period.weekOf)
            guard breakdown.totalEarned > 0 else {
                // Do not prematurely close allowance periods for heroes with $0 earnings.
                return
            }
            updated.totalEarned = breakdown.totalEarned
            updated.questsCompleted = breakdown.questsCount
        } else {
            guard (updated.totalEarned) > 0 else {
                return
            }
        }

        updated.status = .paid
        updated.paidDate = Date()
        updated.paidAmount = updated.totalEarned

        let name = period.id.recordName
        let snapshot = cacheService?.fetchAllowancePeriods(family: period.family.recordID.recordName).first(where: { $0.recordName == name })

        let preMutationChangeTag = snapshot?.changeTag
        let snapshotPeriod: AllowancePeriod? = snapshot?.toAllowancePeriod(zoneID: cloudKit.resolvedZoneID)

        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertAllowancePeriod(updated)

        do {
            let saved = try await cloudKit.save(updated)
            cacheService?.upsertAllowancePeriod(saved)

            if let notificationService {
                Task { [logger] in
                    do {
                        let profile = try await cloudKit.fetch(Profile.self, id: period.profile.recordID)
                        let family = try await cloudKit.fetch(Family.self, id: period.family.recordID)
                        try await notificationService.sendWeeklySummary(to: profile, family: family, weekOf: period.weekOf)
                    } catch {
                        logger.error("Failed to send weekly summary notification: \(error, privacy: .public)")
                    }
                }
            }
            await registry?.deregister(name)
        } catch {
            let concurrentEditDetected = ConcurrentEditDetector.detectConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { cacheService?.fetchAllowancePeriods(family: period.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                error: error
            )

            if concurrentEditDetected {
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
            await registry?.deregister(name)
            throw error
        }
    }

    /// Process real-time settlement for heroes with `.realTime` payout policy.
    @discardableResult
    func processRealTimeSettlement(profile: Profile, family: Family, date: Date = Date()) async throws -> AllowancePeriod? {
        // Real-time settlement is a self-action: the hero who completed the
        // quest triggers this on their own profile. Identity-only check; we
        // return nil so the real-time Task in QuestService.applyReward
        // gracefully no-ops on identity mismatch (defense-in-depth alongside
        // the markComplete parent-role guard).
        guard let acting = appState?.currentProfile,
              acting.id == profile.id else { return nil }

        guard profile.payoutPolicy == .realTime else { return nil }
        let weekOf = WeekMath.startOfWeek(for: date, payoutDay: profile.payoutDay ?? family.payoutDay)
        let period = try await getOrCreateAllowancePeriod(profile: profile, weekOf: weekOf, family: family)

        let breakdown = try await weeklyBreakdown(profile: profile, family: family, weekOf: weekOf)

        var updated = period
        updated.paidAmount = breakdown.totalEarned
        updated.paidDate = Date()
        if period.paidAmount != updated.paidAmount {
            // Persist the FRESH breakdown totals so the period's economic
            // snapshot stays consistent with the gold settled so far. Passing
            // the pre-settlement period values here would let `updateAllowance`
            // keep the creation-time zeros (its `?? breakdown` fallback never
            // fires for non-optional fields). `questsTotal` is intentionally
            // omitted — the weekly breakdown exposes only the completed count,
            // and the period's quest total is fixed at creation.
            return try await updateAllowance(period: updated,
                                             totalEarned: breakdown.totalEarned,
                                             questsCompleted: breakdown.questsCount)
        }
        return period
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    private func goldFromQuests(profile: Profile) async throws -> Double {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cachedCompletions = cache.fetchQuestCompletions(family: familyName)
                .filter { $0.completerRecordName == profileName }
            if !cachedCompletions.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .questCompletion) {
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
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchLedgerEntries(
                profileRecordName: profile.id.recordName,
                family: familyName
            )
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .ledgerEntry) {
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
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .allowancePeriod) {
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
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchLedgerEntries(
                profileRecordName: profile.id.recordName,
                family: familyName
            )
            let filtered = cached.filter { dateRange.contains($0.date) }
            if !filtered.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .ledgerEntry) {
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
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchQuestCompletions(family: familyName)
                .filter { $0.completerRecordName == profileName && $0.weekOf >= weekStarting && $0.weekOf < weekEnding }
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .questCompletion) {
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
        let startOfWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: profile.payoutDay ?? .sunday)

        let range = TreasuryService.weekRange(starting: startOfWeek)

        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchQuests(family: familyName)
                .filter { $0.assigneeRecordName == profileName && range.contains($0.weekOf) }
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .quest) {
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
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchAllowancePeriods(profileRecordName: profileName, family: familyName)
                .first { Calendar.iso8601UTC.isDate($0.weekOf, inSameDayAs: weekOf) }
            if let cached, cache.isCacheFresh(familyRecordName: familyName, type: .allowancePeriod) {
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
