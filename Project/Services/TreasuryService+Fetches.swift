//
//  TreasuryService+Fetches.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os

// MARK: - Cache-First Fetches & Helpers

extension TreasuryService {
    func fetchAllLedgerEntries(profile: Profile) async throws -> [LedgerEntry] {
        let familyName = profile.family.recordID.recordName
        if let cache = cacheService {
            let cached = cache.fetchLedgerEntries(
                profileRecordName: profile.id.recordName,
                family: familyName
            )
            if cache.isCacheFresh(familyRecordName: familyName, type: .ledgerEntry) {
                return cached.map { $0.toLedgerEntry(zoneID: profile.id.zoneID) }
            }
            // Brand-new hero may not be marked fresh yet — fall back to cached
            // rows on CloudKit failure rather than throwing.
            if !cached.isEmpty {
                do {
                    let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                    let predicate = NSPredicate(format: "profile == %@", profileRef as CVarArg)
                    let entries = try await cloudKit.query(LedgerEntry.self, predicate: predicate, in: profile.id.zoneID)
                    cacheService?.upsertLedgerEntries(entries)
                    return entries
                } catch {
                    logger.warning("fetchAllLedgerEntries fallback to cache: \(error, privacy: .private)")
                    return cached.map { $0.toLedgerEntry(zoneID: profile.id.zoneID) }
                }
            }
        }
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "profile == %@",
                                    profileRef as CVarArg)
        do {
            let entries = try await cloudKit.query(LedgerEntry.self, predicate: predicate, in: profile.id.zoneID)
            cacheService?.upsertLedgerEntries(entries)
            return entries
        } catch {
            logger.warning("fetchAllLedgerEntries CloudKit failure with no cache: \(error, privacy: .private)")
            if let cache = cacheService {
                let cached = cache.fetchLedgerEntries(profileRecordName: profile.id.recordName, family: familyName)
                if !cached.isEmpty {
                    return cached.map { $0.toLedgerEntry(zoneID: profile.id.zoneID) }
                }
            }
            return []
        }
    }

    func fetchAllowancePeriods(family: Family) async -> [AllowancePeriod] {
        let familyName = family.id.recordName
        if let cache = cacheService {
            let cached = cache.fetchAllowancePeriods(family: familyName)
            if cache.isCacheFresh(familyRecordName: familyName, type: .allowancePeriod) {
                return cached.map { $0.toAllowancePeriod(zoneID: family.id.zoneID) }
            }
        }

        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let all: [AllowancePeriod]
        do {
            all = try await cloudKit.query(
                AllowancePeriod.self,
                predicate: predicate,
                in: family.id.zoneID,
                sortDescriptors: [NSSortDescriptor(key: "weekOf", ascending: false)]
            )
        } catch {
            logger.warning("Failed to fetch allowance periods: \(error, privacy: .private)")
            all = []
        }
        cacheService?.upsertAllowancePeriods(all)
        return all
    }

    func fetchLedgerEntries(profile: Profile, in dateRange: Range<Date>) async throws -> [LedgerEntry] {
        let profileName = profile.id.recordName
        let familyName = profile.family.recordID.recordName
        if let cache = cacheService {
            let cached = cache.fetchLedgerEntries(profileRecordName: profileName, family: familyName)
            let filtered = cached.filter { dateRange.contains($0.date) }
            if cache.isCacheFresh(familyRecordName: familyName, type: .ledgerEntry) {
                return filtered.map { $0.toLedgerEntry(zoneID: profile.id.zoneID) }
            }
            // Allow zero-history hero to use cache even when not stamped fresh.
            // CloudKit may be unreachable offline; return filtered cache on failure.
            do {
                let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                let predicate = NSPredicate(
                    format: "profile == %@ AND date >= %@ AND date < %@",
                    profileRef as CVarArg,
                    dateRange.lowerBound as CVarArg,
                    dateRange.upperBound as CVarArg
                )
                let entries = try await cloudKit.query(LedgerEntry.self, predicate: predicate, in: profile.id.zoneID)
                cacheService?.upsertLedgerEntries(entries)
                return entries
            } catch {
                logger.warning("fetchLedgerEntries fallback to cache: \(error, privacy: .private)")
                return filtered.map { $0.toLedgerEntry(zoneID: profile.id.zoneID) }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(
            format: "profile == %@ AND date >= %@ AND date < %@",
            profileRef as CVarArg,
            dateRange.lowerBound as CVarArg,
            dateRange.upperBound as CVarArg
        )
        do {
            let entries = try await cloudKit.query(LedgerEntry.self, predicate: predicate, in: profile.id.zoneID)
            cacheService?.upsertLedgerEntries(entries)
            return entries
        } catch {
            logger.warning("fetchLedgerEntries CloudKit failure: \(error, privacy: .private)")
            if let cache = cacheService {
                let cached = cache.fetchLedgerEntries(profileRecordName: profileName, family: familyName)
                return cached.filter { dateRange.contains($0.date) }.map { $0.toLedgerEntry(zoneID: profile.id.zoneID) }
            }
            return []
        }
    }

    func fetchQuestLogs(profile: Profile,
                        weekStarting: Date,
                        weekEnding: Date) async throws -> [QuestCompletion]
    {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchQuestCompletions(family: familyName)
                .filter { $0.completerRecordName == profileName && $0.weekOf >= weekStarting && $0.weekOf < weekEnding }
            if cache.isCacheFresh(familyRecordName: familyName, type: .questCompletion) {
                return cached.map { $0.toQuestCompletion(zoneID: profile.id.zoneID) }
            }
            // Brand-new hero has zero logs; a missing freshness stamp must not
            // force a CloudKit throw that breaks weekly breakdown for seeding.
            if cached.isEmpty {
                do {
                    let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                    let predicate = NSPredicate(format: "completedBy == %@", profileRef as CVarArg)
                    let all = try await cloudKit.query(QuestCompletion.self, predicate: predicate, in: profile.id.zoneID)
                    cacheService?.upsertQuestCompletions(all)
                    return all.filter { $0.weekOf >= weekStarting && $0.weekOf < weekEnding }
                } catch {
                    logger.warning("fetchQuestLogs fallback to empty cache: \(error, privacy: .private)")
                    return []
                }
            }
            do {
                let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                let predicate = NSPredicate(format: "completedBy == %@", profileRef as CVarArg)
                let all = try await cloudKit.query(QuestCompletion.self, predicate: predicate, in: profile.id.zoneID)
                cacheService?.upsertQuestCompletions(all)
                return all.filter { $0.weekOf >= weekStarting && $0.weekOf < weekEnding }
            } catch {
                logger.warning("fetchQuestLogs fallback to cached: \(error, privacy: .private)")
                return cached.map { $0.toQuestCompletion(zoneID: profile.id.zoneID) }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "completedBy == %@", profileRef as CVarArg)
        do {
            let all = try await cloudKit.query(QuestCompletion.self, predicate: predicate, in: profile.id.zoneID)
            cacheService?.upsertQuestCompletions(all)
            return all.filter { $0.weekOf >= weekStarting && $0.weekOf < weekEnding }
        } catch {
            logger.warning("fetchQuestLogs CloudKit failure: \(error, privacy: .private)")
            return []
        }
    }

    func fetchAssignedQuests(profile: Profile,
                             family: Family,
                             weekOf: Date) async throws -> [Quest]
    {
        let payoutDay = profile.payoutDay ?? family.payoutDay
        let range = TreasuryService.weekRange(starting: WeekMath.startOfWeek(for: weekOf, payoutDay: payoutDay))
        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchQuests(family: familyName)
            let filtered = cached.filter {
                $0.assigneeRecordName == profile.id.recordName &&
                    $0.isActive &&
                    range.contains($0.weekOf)
            }
            if cache.isCacheFresh(familyRecordName: familyName, type: .quest) {
                return filtered.map { $0.toQuest(zoneID: family.id.zoneID) }
            }
            // New hero has no assigned quests this week; do not require a fresh
            // cache or a successful CloudKit query to return an empty set.
            if filtered.isEmpty, cached.isEmpty {
                do {
                    let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
                    let predicate = NSPredicate(format: "family == %@ AND isActive == 1", familyRef as CVarArg)
                    let all = try await cloudKit.query(Quest.self, predicate: predicate, in: family.id.zoneID)
                    cacheService?.upsertQuests(all)
                    return all.filter { range.contains($0.weekOf) && $0.assignee.recordID == profile.id }
                } catch {
                    logger.warning("fetchAssignedQuests fallback to empty: \(error, privacy: .private)")
                    return []
                }
            }
            do {
                let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
                let predicate = NSPredicate(format: "family == %@ AND isActive == 1", familyRef as CVarArg)
                let all = try await cloudKit.query(Quest.self, predicate: predicate, in: family.id.zoneID)
                cacheService?.upsertQuests(all)
                return all.filter { range.contains($0.weekOf) }
            } catch {
                logger.warning("fetchAssignedQuests fallback to cached: \(error, privacy: .private)")
                return filtered.map { $0.toQuest(zoneID: family.id.zoneID) }
            }
        }

        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(
            format: "family == %@ AND isActive == 1",
            familyRef as CVarArg
        )
        do {
            let all = try await cloudKit.query(Quest.self, predicate: predicate, in: family.id.zoneID)
            cacheService?.upsertQuests(all)
            return all.filter { range.contains($0.weekOf) }
        } catch {
            logger.warning("fetchAssignedQuests CloudKit failure: \(error, privacy: .private)")
            return []
        }
    }

    func fetchAllowancePeriod(profile: Profile,
                              weekOf: Date) async throws -> AllowancePeriod?
    {
        let familyName = profile.family.recordID.recordName
        // Normalize both sides to start-of-day to avoid daylight-edge mismatches
        // where isDate(inSameDayAs:) can diverge on DST boundaries.
        let normalizedWeekStart = Calendar.iso8601UTC.startOfDay(for: weekOf)
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let cached = cache.fetchAllowancePeriods(profileRecordName: profileName, family: familyName)
                .first { Calendar.iso8601UTC.startOfDay(for: $0.weekOf) == normalizedWeekStart }
            if cache.isCacheFresh(familyRecordName: familyName, type: .allowancePeriod) {
                return cached?.toAllowancePeriod(zoneID: profile.id.zoneID)
            }
            // Brand-new hero has no AllowancePeriod yet — that is a valid
            // "not found" not an error. Fall back to cached nil rather than
            // requiring a successful CloudKit query offline.
            if cached != nil {
                do {
                    let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                    let predicate = NSPredicate(format: "profile == %@ AND weekOf == %@", profileRef as CVarArg, weekOf as CVarArg)
                    let periods = try await cloudKit.query(AllowancePeriod.self, predicate: predicate, in: profile.id.zoneID)
                    cacheService?.upsertAllowancePeriods(periods)
                    return periods.first ?? cached?.toAllowancePeriod(zoneID: profile.id.zoneID)
                } catch {
                    logger.warning("fetchAllowancePeriod fallback to cached: \(error, privacy: .private)")
                    return cached?.toAllowancePeriod(zoneID: profile.id.zoneID)
                }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(
            format: "profile == %@ AND weekOf == %@",
            profileRef as CVarArg,
            weekOf as CVarArg
        )
        do {
            let periods = try await cloudKit.query(AllowancePeriod.self,
                                                   predicate: predicate,
                                                   in: profile.id.zoneID)
            cacheService?.upsertAllowancePeriods(periods)
            return periods.first
        } catch {
            logger.warning("fetchAllowancePeriod CloudKit failure: \(error, privacy: .private)")
            if let cache = cacheService {
                let cached = cache.fetchAllowancePeriods(profileRecordName: profile.id.recordName, family: familyName)
                    .first { Calendar.iso8601UTC.isDate($0.weekOf, inSameDayAs: weekOf) }
                return cached?.toAllowancePeriod(zoneID: profile.id.zoneID)
            }
            return nil
        }
    }

    func resolveProfile(recordID: CKRecord.ID, familyRecordName: String) async throws -> Profile {
        if let cache = cacheService,
           let cached = cache.fetchProfile(recordName: recordID.recordName, family: familyRecordName)
        {
            return cached.toProfile(zoneID: recordID.zoneID)
        }
        if let cache = cacheService,
           let scanned = cache.fetchProfiles(family: familyRecordName).first(where: { $0.recordName == recordID.recordName })
        {
            return scanned.toProfile(zoneID: recordID.zoneID)
        }
        let fetched = try await cloudKit.fetch(Profile.self, id: recordID)
        guard fetched.family.recordID.recordName == familyRecordName else {
            throw FamilyServiceError.unauthorized
        }
        cacheService?.upsertProfile(fetched)
        return fetched
    }

    func resolveFamily(recordID: CKRecord.ID) async throws -> Family {
        if let cache = cacheService,
           let cached = cache.fetchFamily(recordName: recordID.recordName)
        {
            return cached.toFamily(zoneID: recordID.zoneID)
        }
        return try await cloudKit.fetch(Family.self, id: recordID)
    }

    // MARK: - Gold Aggregation

    // Zone-aware gold summation: delegates to `GoldCalculation.totalCredit` which
    // keys quests by `recordName` (zone-independent) and surfaces transient
    // CloudKit fetch failures instead of silently under-crediting.
    //
    // - Throws: Re-throws any `GoldCalculation.totalCredit` fetch failure.
    //   Callers (notably `weeklyBreakdown` and `processRealTimeSettlement`)
    //   must handle with `do/catch` + `ToastManager.show` + retry; do not
    //   `try?` to `0` or leave the wallet hanging.

    // MARK: - Helpers

    func effectivePayoutPolicy(for profile: Profile, family: Family? = nil) -> PayoutPolicy {
        if profile.payoutPolicy != .perQuest {
            return profile.payoutPolicy
        }
        return family?.payoutPolicy ?? profile.payoutPolicy
    }

    func sumGold(for logs: [QuestCompletion], family: Family? = nil) async throws -> Double {
        try await GoldCalculation.totalCredit(
            logs: logs,
            cacheService: cacheService,
            cloudKit: cloudKit,
            family: family
        )
    }

    static func isCompleted(_ log: QuestCompletion) -> Bool {
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
