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
    }

    func weeklyBreakdown(profile: Profile,
                         weekOf: Date) async throws -> WeeklyBreakdown
    {
        let monday = TreasuryService.mondayOfWeek(for: weekOf)
        let weekRange = TreasuryService.weekRange(starting: monday)

        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: monday,
                                            weekEnding: weekRange.end)
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
                                                .weekRange(starting: monday).end)
        let slainCount = logs.filter { TreasuryService.isSlain($0) }.count

        let period = AllowancePeriod(
            weekOf: monday,
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            questsTotal: slainCount,
            family: CKRecord.Reference(recordID: family.id, action: .none)
        )
        let saved = try await cloudKit.save(period)
        cacheService?.upsertAllowancePeriod(saved)
        return saved
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
        let saved = try await cloudKit.save(updated)
        cacheService?.upsertAllowancePeriod(saved)
        return saved
    }

    func runPayout(period: AllowancePeriod) async throws {
        var updated = period
        updated.status = .paid
        updated.paidDate = Date()
        updated.paidAmount = updated.totalEarned
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
    }

    private func goldFromQuests(profile: Profile) async throws -> Double {
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "completedBy == %@",
                                    profileRef as CVarArg)
        let logs = try await cloudKit.query(QuestCompletion.self,
                                            predicate: predicate)
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
                return cached.map { ledgerEntryFromCache($0, zoneID: cloudKit.resolvedZoneID) }
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

    /// Cache-first read of ALL `AllowancePeriod` records for a family
    /// (newest week first). Mirrors `fetchAllLedgerEntries`:
    /// - If the cache has any periods for this family, return them
    ///   synchronously and kick a background CloudKit refresh that
    ///   upserts the fresh rows into the cache.
    /// - Otherwise fall back to a direct CloudKit query, upsert the
    ///   result, and return it.
    ///
    /// Used by `FamilyDashboardViewModel.loadPastPayouts` so payout rows
    /// render instantly while CloudKit propagation catches up — which makes
    /// the late-propagation retry in `handleRecordChangedSync` cheap.
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
                return cached.map { allowancePeriodFromCache($0, zoneID: zoneID) }
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
                                    in dateRange: DateInterval) async throws -> [LedgerEntry]
    {
        if let cache = cacheService {
            let cached = cache.fetchLedgerEntries(profileRecordName: profile.id.recordName)
            let filtered = cached.filter { dateRange.contains($0.date) }
            if !filtered.isEmpty {
                Task { [cloudKit, cacheService] in
                    let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                    let predicate = NSPredicate(
                        format: "profile == %@ AND date >= %@ AND date <= %@",
                        profileRef as CVarArg,
                        dateRange.start as CVarArg,
                        dateRange.end as CVarArg
                    )
                    if let fresh = try? await cloudKit.query(LedgerEntry.self, predicate: predicate) {
                        cacheService?.upsertLedgerEntries(fresh)
                    }
                }
                return filtered.map { ledgerEntryFromCache($0, zoneID: cloudKit.resolvedZoneID) }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(
            format: "profile == %@ AND date >= %@ AND date <= %@",
            profileRef as CVarArg,
            dateRange.start as CVarArg,
            dateRange.end as CVarArg
        )
        let entries = try await cloudKit.query(LedgerEntry.self, predicate: predicate)
        cacheService?.upsertLedgerEntries(entries)
        return entries
    }

    private func fetchQuestLogs(profile: Profile,
                                weekStarting: Date,
                                weekEnding: Date) async throws -> [QuestCompletion]
    {
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "completedBy == %@", profileRef as CVarArg)
        let all = try await cloudKit.query(QuestCompletion.self, predicate: predicate)
        return all.filter { $0.weekOf >= weekStarting && $0.weekOf <= weekEnding }
    }

    private func fetchAssignedQuests(profile: Profile, weekOf: Date) async throws -> [Quest] {
        let range = TreasuryService.weekRange(starting: TreasuryService.mondayOfWeek(for: weekOf))
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "assignee == %@", profileRef as CVarArg)
        let all = try await cloudKit.query(Quest.self, predicate: predicate)
        return all.filter { range.contains($0.weekOf) }
    }

    private func fetchAllowancePeriod(profile: Profile,
                                      weekOf: Date) async throws -> AllowancePeriod?
    {
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(
            format: "profile == %@ AND weekOf == %@",
            profileRef as CVarArg,
            weekOf as CVarArg
        )
        let periods = try await cloudKit.query(AllowancePeriod.self,
                                               predicate: predicate)
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

        for chunk in uniqueQuestIDs.chunked(into: 100) {
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

    static func weekRange(starting monday: Date) -> DateInterval {
        let cal = Calendar.iso8601UTC
        let start = cal.startOfDay(for: monday)

        let end = cal.date(byAdding: .second, value: AppConstants.Time.secondsInWeek - 1,
                           to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    static func mondayOfWeek(for date: Date) -> Date {
        let cal = Calendar.iso8601UTC
        let components = cal.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: date
        )
        return cal.date(from: components) ?? cal.startOfDay(for: date)
    }

    private func ledgerEntryFromCache(_ cache: LedgerEntryCache, zoneID: CKRecordZone.ID) -> LedgerEntry {
        LedgerEntry(
            profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: cache.profileRecordName, zoneID: zoneID), action: .none),
            amount: cache.amount,
            description: cache.entryDescription,
            date: cache.date,
            source: cache.source,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: cache.familyRecordName, zoneID: zoneID), action: .none),
            id: CKRecord.ID(recordName: cache.recordName, zoneID: zoneID)
        )
    }

    /// Reconstructs an `AllowancePeriod` from its SwiftData cache row, mirroring
    /// `ledgerEntryFromCache`. Used by the cache-first `fetchAllowancePeriods`
    /// read path so callers can render past payouts without an async CloudKit hit.
    private func allowancePeriodFromCache(_ cache: AllowancePeriodCache, zoneID: CKRecordZone.ID) -> AllowancePeriod {
        var period = AllowancePeriod(
            weekOf: cache.weekOf,
            profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: cache.profileRecordName, zoneID: zoneID), action: .none),
            questsTotal: cache.questsTotal,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: cache.familyRecordName, zoneID: zoneID), action: .none),
            id: CKRecord.ID(recordName: cache.recordName, zoneID: zoneID)
        )
        period.status = PayoutStatus(rawValue: cache.status) ?? .active
        period.totalEarned = cache.totalEarned
        period.questsCompleted = cache.questsCompleted
        period.paidDate = cache.paidDate
        period.paidAmount = cache.paidAmount
        return period
    }
}
