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
        let scope: CKDatabase.Scope = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared
        let cache = cacheService
        let cached = cache.fetchLedgerEntries(
            profileRecordName: profile.id.recordName,
            family: familyName
        )
        if cache.isCacheAuthoritative(familyRecordName: familyName, type: .ledgerEntry, scope: scope, cachedCount: cached.count) {
            return cached.map { $0.toLedgerEntry(zoneID: profile.id.zoneID) }
        }
        // Brand-new hero may not be marked fresh yet — fall back to cached
        // rows on CloudKit failure rather than throwing.
        if !cached.isEmpty {
            do {
                let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                let predicate = NSPredicate(format: "profile == %@", profileRef as CVarArg)
                let entries = try await cloudKit.query(LedgerEntry.self, predicate: predicate, in: profile.id.zoneID)
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: entries,
                    databaseScope: scope,
                    zoneID: profile.id.zoneID
                )
                return entries
            } catch {
                logger.warning("fetchAllLedgerEntries fallback to cache: \(error, privacy: .private)")
                return cached.map { $0.toLedgerEntry(zoneID: profile.id.zoneID) }
            }
        }
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "profile == %@",
                                    profileRef as CVarArg)
        do {
            let entries = try await cloudKit.query(LedgerEntry.self, predicate: predicate, in: profile.id.zoneID)
            await syncCoordinator.delegateHandler.hydrateFromQuery(
                models: entries,
                databaseScope: scope,
                zoneID: profile.id.zoneID
            )
            return entries
        } catch {
            logger.warning("fetchAllLedgerEntries CloudKit failure with no cache: \(error, privacy: .private)")
            let fallback = cache.fetchLedgerEntries(profileRecordName: profile.id.recordName, family: familyName)
            if !fallback.isEmpty {
                return fallback.map { $0.toLedgerEntry(zoneID: profile.id.zoneID) }
            }
            return []
        }
    }

    func fetchAllowancePeriods(family: Family) async -> [AllowancePeriod] {
        let familyName = family.id.recordName
        let scope: CKDatabase.Scope = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared
        let cache = cacheService
        let cached = cache.fetchAllowancePeriods(family: familyName)
        if cache.isCacheAuthoritative(familyRecordName: familyName, type: .allowancePeriod, scope: scope, cachedCount: cached.count) {
            return cached.map { $0.toAllowancePeriod(zoneID: family.id.zoneID) }
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
        await syncCoordinator.delegateHandler.hydrateFromQuery(
            models: all,
            databaseScope: scope,
            zoneID: family.id.zoneID
        )
        return all
    }

    func fetchLedgerEntries(profile: Profile, in dateRange: Range<Date>) async throws -> [LedgerEntry] {
        let profileName = profile.id.recordName
        let familyName = profile.family.recordID.recordName
        let scope: CKDatabase.Scope = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared
        let cache = cacheService
        let cached = cache.fetchLedgerEntries(profileRecordName: profileName, family: familyName)
        let filtered = cached.filter { dateRange.contains($0.date) }
        if cache.isCacheAuthoritative(familyRecordName: familyName, type: .ledgerEntry, scope: scope, cachedCount: cached.count) {
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
            await syncCoordinator.delegateHandler.hydrateFromQuery(
                models: entries,
                databaseScope: scope,
                zoneID: profile.id.zoneID
            )
            return entries
        } catch {
            logger.warning("fetchLedgerEntries fallback to cache: \(error, privacy: .private)")
            return filtered.map { $0.toLedgerEntry(zoneID: profile.id.zoneID) }
        }
    }

    func fetchQuestLogs(profile: Profile,
                        weekStarting: Date,
                        weekEnding: Date) async throws -> [QuestCompletion]
    {
        let scope: CKDatabase.Scope = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared
        let cache = cacheService
        let profileName = profile.id.recordName
        let familyName = profile.family.recordID.recordName
        let cached = cache.fetchQuestCompletions(family: familyName)
            .filter { $0.completerRecordName == profileName && $0.weekOf >= weekStarting && $0.weekOf < weekEnding }
        // WHY: freshness-only sole authority — stale cache must re-validate via CloudKit; empty-cache-offline rendering handled explicitly at call site (FamilyService-style).
        if cache.isCacheAuthoritative(familyRecordName: familyName, type: .questCompletion, scope: scope, cachedCount: cached.count) {
            return cached.map { $0.toQuestCompletion(zoneID: profile.id.zoneID) }
        }
        // Brand-new hero has zero logs; a missing freshness stamp must not
        // force a CloudKit throw that breaks weekly breakdown for seeding.
        if cached.isEmpty {
            do {
                let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                let predicate = NSPredicate(format: "completedBy == %@", profileRef as CVarArg)
                let all = try await cloudKit.query(QuestCompletion.self, predicate: predicate, in: profile.id.zoneID)
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: all,
                    databaseScope: scope,
                    zoneID: profile.id.zoneID
                )
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
            await syncCoordinator.delegateHandler.hydrateFromQuery(
                models: all,
                databaseScope: scope,
                zoneID: profile.id.zoneID
            )
            return all.filter { $0.weekOf >= weekStarting && $0.weekOf < weekEnding }
        } catch {
            logger.warning("fetchQuestLogs fallback to cached: \(error, privacy: .private)")
            return cached.map { $0.toQuestCompletion(zoneID: profile.id.zoneID) }
        }
    }

    func fetchAssignedQuests(profile: Profile,
                             family: Family,
                             weekOf: Date) async throws -> [Quest]
    {
        let payoutDay = profile.payoutDay ?? family.payoutDay
        let range = TreasuryService.weekRange(starting: WeekMath.startOfWeek(for: weekOf, payoutDay: payoutDay))
        let scope: CKDatabase.Scope = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared
        let cache = cacheService
        let familyName = family.id.recordName
        let cachedAll = cache.fetchQuests(family: familyName)
        let filtered = cachedAll.filter {
            $0.assigneeRecordName == profile.id.recordName &&
                $0.isActive &&
                range.contains($0.weekOf)
        }
        if cache.isCacheAuthoritative(familyRecordName: familyName, type: .quest, scope: scope, cachedCount: cachedAll.count) {
            return filtered.map { $0.toQuest(zoneID: family.id.zoneID) }
        }
        // New hero has no assigned quests this week; do not require a fresh
        // cache or a successful CloudKit query to return an empty set.
        if filtered.isEmpty, cachedAll.isEmpty {
            do {
                let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
                let predicate = NSPredicate(format: "family == %@ AND isActive == 1", familyRef as CVarArg)
                let all = try await cloudKit.query(Quest.self, predicate: predicate, in: family.id.zoneID)
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: all,
                    databaseScope: scope,
                    zoneID: family.id.zoneID
                )
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
            await syncCoordinator.delegateHandler.hydrateFromQuery(
                models: all,
                databaseScope: scope,
                zoneID: family.id.zoneID
            )
            return all.filter { range.contains($0.weekOf) && $0.assignee.recordID == profile.id }
        } catch {
            logger.warning("fetchAssignedQuests fallback to cached: \(error, privacy: .private)")
            return filtered.map { $0.toQuest(zoneID: family.id.zoneID) }
        }
    }

    func fetchAllowancePeriod(profile: Profile,
                              weekOf: Date) async throws -> AllowancePeriod?
    {
        let familyName = profile.family.recordID.recordName
        // Strict equality on normalized UTC week start matches stored AllowancePeriod.weekOf exactly.
        let normalizedWeekStart = Calendar.iso8601UTC.startOfDay(for: weekOf)
        let scope: CKDatabase.Scope = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared
        let cache = cacheService
        let profileName = profile.id.recordName
        let cached = cache.fetchAllowancePeriods(profileRecordName: profileName, family: familyName)
            .first { $0.weekOf == normalizedWeekStart }
        // WHY: freshness-only sole authority — stale cache must re-validate via CloudKit; empty-cache-offline rendering handled explicitly at call site (FamilyService-style).
        if cache.isCacheAuthoritative(familyRecordName: familyName, type: .allowancePeriod, scope: scope, cachedCount: cached != nil ? 1 : 0) {
            return cached?.toAllowancePeriod(zoneID: profile.id.zoneID)
        }
        // Brand-new hero has no AllowancePeriod yet — that is a valid
        // "not found" not an error. Explicit fallback at call site — fall back to cached nil rather than requiring successful CloudKit query offline.
        if cached != nil {
            do {
                let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                let predicate = NSPredicate(format: "profile == %@ AND weekOf == %@", profileRef as CVarArg, normalizedWeekStart as CVarArg)
                let periods = try await cloudKit.query(AllowancePeriod.self, predicate: predicate, in: profile.id.zoneID)
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: periods,
                    databaseScope: scope,
                    zoneID: profile.id.zoneID
                )
                return periods.first ?? cached?.toAllowancePeriod(zoneID: profile.id.zoneID)
            } catch {
                logger.warning("fetchAllowancePeriod fallback to cached: \(error, privacy: .private)")
                return cached?.toAllowancePeriod(zoneID: profile.id.zoneID)
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(
            format: "profile == %@ AND weekOf == %@",
            profileRef as CVarArg,
            normalizedWeekStart as CVarArg
        )
        do {
            let periods = try await cloudKit.query(AllowancePeriod.self,
                                                   predicate: predicate,
                                                   in: profile.id.zoneID)
            await syncCoordinator.delegateHandler.hydrateFromQuery(
                models: periods,
                databaseScope: scope,
                zoneID: profile.id.zoneID
            )
            return periods.first
        } catch {
            logger.warning("fetchAllowancePeriod CloudKit failure: \(error, privacy: .private)")
            let fallback = cache.fetchAllowancePeriods(profileRecordName: profile.id.recordName, family: familyName)
                .first { $0.weekOf == normalizedWeekStart }
            return fallback?.toAllowancePeriod(zoneID: profile.id.zoneID)
        }
    }

    func resolveProfile(recordID: CKRecord.ID, familyRecordName: String) async throws -> Profile {
        if let cached = cacheService.fetchProfile(recordName: recordID.recordName, family: familyRecordName) {
            return cached.toProfile(zoneID: recordID.zoneID)
        }
        if let scanned = cacheService.fetchProfiles(family: familyRecordName).first(where: { $0.recordName == recordID.recordName }) {
            return scanned.toProfile(zoneID: recordID.zoneID)
        }
        let scope: CKDatabase.Scope = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared
        let fetched = try await cloudKit.fetch(Profile.self, id: recordID)
        guard fetched.family.recordID.recordName == familyRecordName else {
            throw FamilyServiceError.unauthorized
        }
        await syncCoordinator.delegateHandler.hydrateFromQuery(
            models: [fetched],
            databaseScope: scope,
            zoneID: recordID.zoneID
        )
        return fetched
    }

    func resolveFamily(recordID: CKRecord.ID) async throws -> Family {
        if let cached = cacheService.fetchFamily(recordName: recordID.recordName) {
            return cached.toFamily(zoneID: recordID.zoneID)
        }
        return try await cloudKit.fetch(Family.self, id: recordID)
    }

    // MARK: - Gold Aggregation

    func fetchQuestsForGold(family: Family, logs: [QuestCompletion]) async throws -> [Quest] {
        guard !logs.isEmpty else { return [] }
        let needed = Set(logs.map(\.quest.recordID.recordName))
        let familyName = family.id.recordName
        let scope: CKDatabase.Scope = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared
        // WHY: freshness-only sole authority — stale cache must re-validate via CloudKit; explicit stale fallback at call site (FamilyService-style).
        let count = cacheService.fetchQuests(family: familyName).count
        let isAuthoritative = cacheService.isCacheAuthoritative(familyRecordName: familyName, type: .quest, scope: scope, cachedCount: count)
        if isAuthoritative {
            let zoneID = family.id.zoneID
            let cached = cacheService.fetchQuests(family: familyName).map { $0.toQuest(zoneID: zoneID) }
            var map = Dictionary(uniqueKeysWithValues: cached.map { ($0.id.recordName, $0) })
            let missing = needed.filter { map[$0] == nil }
            if missing.isEmpty {
                return cached.filter { needed.contains($0.id.recordName) }
            }
            let fetched = try await fetchMissingQuestsForGold(
                missingNames: Array(missing),
                family: family,
                logs: logs
            )
            for quest in fetched {
                map[quest.id.recordName] = quest
            }
            return Array(map.values).filter { needed.contains($0.id.recordName) }
        }
        return try await fetchMissingQuestsForGold(
            missingNames: Array(needed),
            family: family,
            logs: logs
        )
    }

    private func fetchMissingQuestsForGold(
        missingNames: [String],
        family: Family,
        logs _: [QuestCompletion]
    ) async throws -> [Quest] {
        try await BatchQuestFetcher.fetchMissingQuests(
            names: missingNames,
            family: family,
            cloudKit: cloudKit
        )
    }

    /// Calculates total gold credit from logs and quests via GoldCalculation.
    func sumGold(for logs: [QuestCompletion], quests: [Quest]) -> Double {
        GoldCalculation.totalCredit(for: quests, logs: logs)
    }

    // MARK: - Helpers

    func effectivePayoutPolicy(for profile: Profile, family: Family? = nil) -> PayoutPolicy {
        if let policy = profile.payoutPolicy {
            return policy
        }
        return family?.payoutPolicy ?? .perQuest
    }

    static func isCompleted(_ log: QuestCompletion) -> Bool {
        log.verificationStatus == .verified || log.verificationStatus == .autoApproved
    }

    static func weekRange(starting monday: Date) -> Range<Date> {
        WeekMath.weekRange(starting: monday)
    }

    static func mondayOfWeek(for date: Date) -> Date {
        WeekMath.mondayOfWeek(for: date)
    }
}
