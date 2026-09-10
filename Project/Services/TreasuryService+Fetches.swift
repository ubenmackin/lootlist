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
    /// WHY derivation-only: payout reconcile needs CloudKit; UI lists use @Query so rows render instantly offline.
    func fetchAllowancePeriods(family: Family) async -> [AllowancePeriod] {
        // WHY fail-closed: unknown scope serves cache only without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            return cacheService.fetchAllowancePeriods(family: family.id.recordName)
                .map { $0.toAllowancePeriod(zoneID: family.id.zoneID) }
                .sorted { $0.weekOf > $1.weekOf }
        }
        do {
            return try await CacheFirst.cacheFirst(
                type: .allowancePeriod,
                family: family,
                cacheService: cacheService,
                scope: scope,
                operations: .init(
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
                    hydrate: { [syncCoordinator, scope, family] models in
                        await syncCoordinator.hydrationHandler.hydrateFromQuery(
                            models: models,
                            databaseScope: scope,
                            zoneID: family.id.zoneID
                        )
                    },
                    sortedBy: { $0.weekOf > $1.weekOf }
                )
            )
        } catch {
            logger.warning("fetchAllowancePeriods fallback to cache: \(error, privacy: .private)")
            // Brand-new hero may not be marked fresh yet — return cached rows (even empty) on CloudKit failure rather than throwing.
            return cacheService.fetchAllowancePeriods(family: family.id.recordName)
                .map { $0.toAllowancePeriod(zoneID: family.id.zoneID) }
                .sorted { $0.weekOf > $1.weekOf }
        }
    }

    /// WHY derivation-only: derivation passthrough to LedgerService; UI balances use bucketBalances/totalBalance cache-only.
    func fetchLedgerEntries(profile: Profile, in dateRange: Range<Date>) async throws -> [LedgerEntry] {
        try await resolvedLedgerService.fetchLedgerEntries(profile: profile, in: dateRange)
    }

    /// WHY derivation-only: payout math reconciles against CloudKit; UI quest lists use @Query cache-only.
    func fetchQuestLogs(profile: Profile,
                        weekStarting: Date,
                        weekEnding: Date) async throws -> [QuestCompletion]
    {
        let family = Family(
            name: "",
            creatorUserRecordName: nil,
            id: CKRecord.ID(recordName: profile.family.recordID.recordName, zoneID: profile.id.zoneID)
        )
        // WHY fail-closed: unknown scope serves cache only without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            return cacheService.fetchQuestCompletions(family: family.id.recordName)
                .map { [profile] cache in cache.toQuestCompletion(zoneID: profile.id.zoneID) }
                .filter { $0.weekOf >= weekStarting && $0.weekOf < weekEnding }
                .filter { $0.completedBy.recordID.recordName == profile.id.recordName }
        }
        let all = try await CacheFirst.cacheFirst(
            type: .questCompletion,
            family: family,
            cacheService: cacheService,
            scope: scope,
            operations: .init(
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
                hydrate: { [syncCoordinator, scope, profile] models in
                    await syncCoordinator.hydrationHandler.hydrateFromQuery(
                        models: models,
                        databaseScope: scope,
                        zoneID: profile.id.zoneID
                    )
                }
            )
        )
        // WeekMath filtering after mapping — half-open [weekStarting, weekEnding).
        return all.filter { $0.weekOf >= weekStarting && $0.weekOf < weekEnding }
            .filter { $0.completedBy.recordID.recordName == profile.id.recordName }
    }

    /// WHY derivation-only: payout math reconciles against CloudKit; UI quest lists use @Query cache-only.
    func fetchAssignedQuests(profile: Profile,
                             family: Family,
                             weekOf: Date) async throws -> [Quest]
    {
        let payoutDay = profile.payoutDay ?? family.payoutDay
        let range = TreasuryService.weekRange(starting: WeekMath.startOfWeek(for: weekOf, payoutDay: payoutDay))
        // WHY fail-closed: unknown scope serves cache only without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            return cacheService.fetchQuests(family: family.id.recordName)
                .map { [family] cache in cache.toQuest(zoneID: family.id.zoneID) }
                .filter {
                    $0.assignee.recordID.recordName == profile.id.recordName &&
                        $0.active &&
                        range.contains($0.weekOf)
                }
        }
        let all = try await CacheFirst.cacheFirst(
            type: .quest,
            family: family,
            cacheService: cacheService,
            scope: scope,
            operations: .init(
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
                hydrate: { [syncCoordinator, scope, family] models in
                    await syncCoordinator.hydrationHandler.hydrateFromQuery(
                        models: models,
                        databaseScope: scope,
                        zoneID: family.id.zoneID
                    )
                }
            )
        )
        // WeekMath filtering after mapping — half-open range derived from payout-day-aware week start.
        return all.filter {
            $0.assignee.recordID.recordName == profile.id.recordName &&
                $0.active &&
                range.contains($0.weekOf)
        }
    }

    // WHY derivation-only: payout lookup reconciles against CloudKit; UI period reads use cached @Query rows.
    // WHY: Single-record filtered lookup with optional CloudKit fallback and bespoke nil-handling — intentionally inline, not a single-type CacheFirst list flow.
    func fetchAllowancePeriod(profile: Profile,
                              weekOf: Date) async throws -> AllowancePeriod?
    {
        let familyName = profile.family.recordID.recordName
        // Strict equality on normalized UTC week start matches stored AllowancePeriod.weekOf exactly.
        let normalizedWeekStart = WeekMath.startOfDay(for: weekOf)
        let cache = cacheService
        let profileName = profile.id.recordName
        let cached = cache.fetchAllowancePeriods(profileRecordName: profileName, family: familyName)
            .first { $0.weekOf == normalizedWeekStart }
        // WHY fail-closed: unknown scope serves cache only without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            return cached?.toAllowancePeriod(zoneID: profile.id.zoneID)
        }
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
                await syncCoordinator.hydrationHandler.hydrateFromQuery(
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
            await syncCoordinator.hydrationHandler.hydrateFromQuery(
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

    /// WHY derivation-only: payout context resolves via cache then CloudKit; UI profiles use @Query cache-only.
    func resolveProfile(recordID: CKRecord.ID, familyRecordName: String) async throws -> Profile {
        if let cached = cacheService.fetchProfile(recordName: recordID.recordName, family: familyRecordName) {
            return cached.toProfile(zoneID: recordID.zoneID)
        }
        if let scanned = cacheService.fetchProfiles(family: familyRecordName).first(where: { $0.recordName == recordID.recordName }) {
            return scanned.toProfile(zoneID: recordID.zoneID)
        }
        // WHY fail-closed: unknown scope never queries with a guessed database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            throw FamilyServiceError.unauthorized
        }
        let fetched = try await cloudKit.fetch(Profile.self, id: recordID)
        guard fetched.family.recordID.recordName == familyRecordName else {
            throw FamilyServiceError.unauthorized
        }
        await syncCoordinator.hydrationHandler.hydrateFromQuery(
            models: [fetched],
            databaseScope: scope,
            zoneID: recordID.zoneID
        )
        return fetched
    }

    /// WHY derivation-only: payout context resolves via cache then CloudKit; UI family reads use @Query cache-only.
    func resolveFamily(recordID: CKRecord.ID) async throws -> Family {
        if let cached = cacheService.fetchFamily(recordName: recordID.recordName) {
            return cached.toFamily(zoneID: recordID.zoneID)
        }
        // WHY fail-closed: unknown scope never queries with a guessed database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            throw FamilyServiceError.unauthorized
        }
        let fetched = try await cloudKit.fetch(Family.self, id: recordID)
        guard !fetched.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FamilyServiceError.unauthorized
        }
        await syncCoordinator.hydrationHandler.hydrateFromQuery(
            models: [fetched],
            databaseScope: scope,
            zoneID: recordID.zoneID
        )
        return fetched
    }

    // MARK: - Gold Aggregation

    /// WHY derivation-only: payout gold math reconciles against CloudKit; UI quest lists use @Query cache-only.
    func fetchQuestsForGold(family: Family, logs: [QuestCompletion]) async throws -> [Quest] {
        guard !logs.isEmpty else { return [] }
        let needed = Set(logs.map(\.quest.recordID.recordName))
        let familyName = family.id.recordName
        let zoneID = family.id.zoneID
        // WHY fail-closed: unknown scope serves cache only without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            return cacheService.fetchQuests(family: familyName)
                .map { $0.toQuest(zoneID: zoneID) }
                .filter { needed.contains($0.id.recordName) }
        }
        let isAuthoritative = cacheService.isCacheAuthoritative(familyRecordName: familyName, type: .quest, scope: scope)
        let cache = cacheService
        // WHY shared stitch: missing-key patch rides CacheFirst so payout
        // and log paths cannot drift; misses hydrate via ingest.
        return try await CacheFirst.resolveWithCache(
            needed: needed,
            isAuthoritative: isAuthoritative,
            fetchCached: { cache.fetchQuests(family: familyName).map { $0.toQuest(zoneID: zoneID) } },
            fetchMissing: { [self] missingNames in
                try await self.fetchMissingQuestsForGold(
                    missingNames: missingNames,
                    family: family,
                    logs: logs,
                    databaseScope: scope,
                    hydrationHandler: syncCoordinator.hydrationHandler
                )
            }
        )
    }

    /// WHY derivation-only: stitch-missing patch hydrates via ingest so the next reconcile hits cache.
    private func fetchMissingQuestsForGold(
        missingNames: [String],
        family: Family,
        logs _: [QuestCompletion],
        databaseScope: CKDatabase.Scope,
        hydrationHandler: any HydrationHandling
    ) async throws -> [Quest] {
        try await BatchQuestFetcher.fetchMissingQuests(
            names: missingNames,
            family: family,
            cloudKit: cloudKit,
            databaseScope: databaseScope,
            hydrationHandler: hydrationHandler
        )
    }

    func sumGold(
        for logs: [QuestCompletion],
        quests: [Quest],
        templatesByID: [String: QuestTemplate]
    ) -> Int64 {
        // WHY day count wins: stale targetCount under-counts specific-days split rewards.
        GoldCalculation.totalCreditPennies(for: quests, logs: logs, templatesByID: templatesByID)
    }

    func sumGold(for logs: [QuestCompletion], quests: [Quest], family: Family) -> Int64 {
        GoldCalculation.totalCreditPennies(
            for: quests,
            logs: logs,
            templatesByID: SpecificDaysHelper.templatesByID(cache: cacheService, familyName: family.id.recordName, zoneID: family.id.zoneID)
        )
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
