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
        let family = Family(
            name: "",
            createdBy: profile.family.recordID,
            id: CKRecord.ID(recordName: profile.family.recordID.recordName, zoneID: profile.id.zoneID)
        )
        return try await CacheFirst.cacheFirst(
            type: .ledgerEntry,
            family: family,
            cacheService: cacheService,
            appState: appState,
            fetchCache: { [cacheService, profile] familyName in
                cacheService.fetchLedgerEntries(profileRecordName: profile.id.recordName, family: familyName)
            },
            map: { [profile] cache in
                cache.toLedgerEntry(zoneID: profile.id.zoneID)
            },
            query: { [cloudKit, profile] in
                let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                let predicate = NSPredicate(format: "profile == %@", profileRef as CVarArg)
                return try await cloudKit.query(LedgerEntry.self, predicate: predicate, in: profile.id.zoneID)
            },
            hydrate: { [syncCoordinator, appState, profile] models in
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: models,
                    databaseScope: appState.activeDatabaseScope,
                    zoneID: profile.id.zoneID
                )
            },
            sortedBy: { $0.date > $1.date }
        )
    }

    func fetchAllowancePeriods(family: Family) async -> [AllowancePeriod] {
        do {
            return try await CacheFirst.cacheFirst(
                type: .allowancePeriod,
                family: family,
                cacheService: cacheService,
                appState: appState,
                fetchCache: { [cacheService] familyName in
                    cacheService.fetchAllowancePeriods(family: familyName)
                },
                map: { [family] cache in
                    cache.toAllowancePeriod(zoneID: family.id.zoneID)
                },
                query: { [cloudKit, family] in
                    let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
                    let predicate = NSPredicate(format: "family == %@", familyRef)
                    return try await cloudKit.query(
                        AllowancePeriod.self,
                        predicate: predicate,
                        in: family.id.zoneID,
                        sortDescriptors: [NSSortDescriptor(key: "weekOf", ascending: false)]
                    )
                },
                hydrate: { [syncCoordinator, appState, family] models in
                    await syncCoordinator.delegateHandler.hydrateFromQuery(
                        models: models,
                        databaseScope: appState.activeDatabaseScope,
                        zoneID: family.id.zoneID
                    )
                },
                sortedBy: { $0.weekOf > $1.weekOf }
            )
        } catch {
            logger.warning("fetchAllowancePeriods fallback to cache: \(error, privacy: .private)")
            // Brand-new hero may not be marked fresh yet — return cached rows (even empty) on CloudKit failure rather than throwing.
            return cacheService.fetchAllowancePeriods(family: family.id.recordName)
                .map { $0.toAllowancePeriod(zoneID: family.id.zoneID) }
                .sorted { $0.weekOf > $1.weekOf }
        }
    }

    func fetchLedgerEntries(profile: Profile, in dateRange: Range<Date>) async throws -> [LedgerEntry] {
        let family = Family(
            name: "",
            createdBy: profile.family.recordID,
            id: CKRecord.ID(recordName: profile.family.recordID.recordName, zoneID: profile.id.zoneID)
        )
        return try await CacheFirst.cacheFirst(
            type: .ledgerEntry,
            family: family,
            cacheService: cacheService,
            appState: appState,
            fetchCache: { [cacheService, profile, dateRange] familyName in
                cacheService.fetchLedgerEntries(profileRecordName: profile.id.recordName, family: familyName)
                    .filter { dateRange.contains($0.date) }
            },
            map: { [profile] cache in
                cache.toLedgerEntry(zoneID: profile.id.zoneID)
            },
            query: { [cloudKit, profile, dateRange] in
                let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                let predicate = NSPredicate(
                    format: "profile == %@ AND date >= %@ AND date < %@",
                    profileRef as CVarArg,
                    dateRange.lowerBound as CVarArg,
                    dateRange.upperBound as CVarArg
                )
                return try await cloudKit.query(LedgerEntry.self, predicate: predicate, in: profile.id.zoneID)
            },
            hydrate: { [syncCoordinator, appState, profile] models in
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: models,
                    databaseScope: appState.activeDatabaseScope,
                    zoneID: profile.id.zoneID
                )
            },
            sortedBy: { $0.date > $1.date }
        )
    }

    func fetchQuestLogs(profile: Profile,
                        weekStarting: Date,
                        weekEnding: Date) async throws -> [QuestCompletion]
    {
        let family = Family(
            name: "",
            createdBy: profile.family.recordID,
            id: CKRecord.ID(recordName: profile.family.recordID.recordName, zoneID: profile.id.zoneID)
        )
        let all = try await CacheFirst.cacheFirst(
            type: .questCompletion,
            family: family,
            cacheService: cacheService,
            appState: appState,
            fetchCache: { [cacheService] familyName in
                cacheService.fetchQuestCompletions(family: familyName)
            },
            map: { [profile] cache in
                cache.toQuestCompletion(zoneID: profile.id.zoneID)
            },
            query: { [cloudKit, profile] in
                let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                let predicate = NSPredicate(format: "completedBy == %@", profileRef as CVarArg)
                return try await cloudKit.query(QuestCompletion.self, predicate: predicate, in: profile.id.zoneID)
            },
            hydrate: { [syncCoordinator, appState, profile] models in
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: models,
                    databaseScope: appState.activeDatabaseScope,
                    zoneID: profile.id.zoneID
                )
            }
        )
        // WeekMath filtering after mapping — half-open [weekStarting, weekEnding).
        return all.filter { $0.weekOf >= weekStarting && $0.weekOf < weekEnding }
            .filter { $0.completedBy.recordID.recordName == profile.id.recordName }
    }

    func fetchAssignedQuests(profile: Profile,
                             family: Family,
                             weekOf: Date) async throws -> [Quest]
    {
        let payoutDay = profile.payoutDay ?? family.payoutDay
        let range = TreasuryService.weekRange(starting: WeekMath.startOfWeek(for: weekOf, payoutDay: payoutDay))
        let all = try await CacheFirst.cacheFirst(
            type: .quest,
            family: family,
            cacheService: cacheService,
            appState: appState,
            fetchCache: { [cacheService] familyName in
                cacheService.fetchQuests(family: familyName)
            },
            map: { [family] cache in
                cache.toQuest(zoneID: family.id.zoneID)
            },
            query: { [cloudKit, family] in
                let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
                let predicate = NSPredicate(format: "family == %@ AND active == 1", familyRef as CVarArg)
                return try await cloudKit.query(Quest.self, predicate: predicate, in: family.id.zoneID)
            },
            hydrate: { [syncCoordinator, appState, family] models in
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: models,
                    databaseScope: appState.activeDatabaseScope,
                    zoneID: family.id.zoneID
                )
            }
        )
        // WeekMath filtering after mapping — half-open range derived from payout-day-aware week start.
        return all.filter {
            $0.assignee.recordID.recordName == profile.id.recordName &&
                $0.active &&
                range.contains($0.weekOf)
        }
    }

    // WHY: Single-record filtered lookup with optional CloudKit fallback and bespoke nil-handling — intentionally inline, not a single-type CacheFirst list flow.
    func fetchAllowancePeriod(profile: Profile,
                              weekOf: Date) async throws -> AllowancePeriod?
    {
        let familyName = profile.family.recordID.recordName
        // Strict equality on normalized UTC week start matches stored AllowancePeriod.weekOf exactly.
        let normalizedWeekStart = Calendar.iso8601UTC.startOfDay(for: weekOf)
        let scope: CKDatabase.Scope = appState.activeDatabaseScope
        let cache = cacheService
        let profileName = profile.id.recordName
        let cached = cache.fetchAllowancePeriods(profileRecordName: profileName, family: familyName)
            .first { $0.weekOf == normalizedWeekStart }
        if cache.isCacheAuthoritative(familyRecordName: familyName, type: .allowancePeriod, scope: scope) {
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
        let scope: CKDatabase.Scope = appState.activeDatabaseScope
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

    // WHY: Bespoke multi-step cache aggregation with missing-key patching — intentionally inline, not a single-type CacheFirst flow.
    func fetchQuestsForGold(family: Family, logs: [QuestCompletion]) async throws -> [Quest] {
        guard !logs.isEmpty else { return [] }
        let needed = Set(logs.map(\.quest.recordID.recordName))
        let familyName = family.id.recordName
        let scope: CKDatabase.Scope = appState.activeDatabaseScope
        let isAuthoritative = cacheService.isCacheAuthoritative(familyRecordName: familyName, type: .quest, scope: scope)
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
