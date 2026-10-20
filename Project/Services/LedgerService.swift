//
//  LedgerService.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import CryptoKit
import Foundation
import os

/// Single owner for all `LedgerEntry` create/fetch/derive-balance logic.
///
/// Treasury keeps allowance periods and payout orchestration; Spending keeps
/// manual-spend UI coordination. Both delegate ledger I/O here so
/// deterministic IDs and the frozen server-wins merge stay single-source.
/// Every mutation follows Services -> CacheService + enqueueSave/enqueueDelete;
/// money copy renders only through `CurrencyFormatter`.
@MainActor
@Observable
final class LedgerService {
    private static let staticLogger = Logger(category: "LedgerService")
    private let logger = Logger(category: "LedgerService")

    let cloudKit: any CloudKitServiceProtocol
    let cacheService: any CacheServicing
    let syncCoordinator: any SyncEnqueuing
    let appState: AppState

    init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: any CacheServicing,
        appState: AppState,
        syncCoordinator: any SyncEnqueuing
    ) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
    }

    @_disfavoredOverload
    convenience init(
        cloudKit: any CloudKitServiceProtocol,
        // swiftformat:disable:next redundantParens
        cacheService: (any CacheServicing)? = nil,
        appState: AppState? = nil,
        // swiftformat:disable:next redundantParens
        syncCoordinator: (any SyncEnqueuing)? = nil
    ) {
        self.init(
            cloudKit: cloudKit,
            cacheService: ServiceInitHelper.resolveCacheService(provided: cacheService, logger: Self.staticLogger, serviceName: "LedgerService"),
            appState: appState ?? AppState(),
            syncCoordinator: ServiceInitHelper.resolveSyncCoordinator(provided: syncCoordinator, logger: Self.staticLogger, serviceName: "LedgerService")
        )
    }

    // MARK: - Cached Reads

    /// WHY cache-only: history lists render from SwiftData with zero CloudKit wait.
    func cachedLedgerEntries(profileRecordName: String, familyRecordName: String) -> [LedgerEntryCache] {
        cacheService.fetchLedgerEntries(profileRecordName: profileRecordName, family: familyRecordName)
    }

    /// WHY cache-only: single-row lookups render from SwiftData with zero CloudKit wait.
    func cachedLedgerEntry(recordName: String, familyRecordName: String) -> LedgerEntryCache? {
        cacheService.fetchLedgerEntry(recordName: recordName, family: familyRecordName)
    }

    // MARK: - Fetches

    /// WHY derivation-only: payout and migration reconcile against CloudKit; UI balances use bucketBalances/totalBalance so tiles render instantly offline.
    func fetchAllLedgerEntries(profile: Profile) async throws -> [LedgerEntry] {
        // WHY single zone: family zone owns scope so profile and family zones must agree.
        let targetZoneID = profile.family.recordID.zoneID
        assert(profile.id.zoneID == profile.family.recordID.zoneID)
        let profileName = profile.id.recordName
        let familyName = profile.family.recordID.recordName
        let family = Family(
            name: "",
            creatorUserRecordName: nil,
            id: CKRecord.ID(recordName: familyName, zoneID: targetZoneID)
        )
        guard let resolved = resolveLedgerScope(targetZoneID: targetZoneID, familyRecordName: familyName) else {
            // WHY cached-only: unknown scope never queries, but serves local cache.
            return cacheService.fetchLedgerEntries(profileRecordName: profileName, family: familyName)
                .map { [targetZoneID] cache in cache.toLedgerEntry(zoneID: targetZoneID) }
                .sorted { $0.date > $1.date }
        }
        let resolvedScope = resolved.scope
        let resolvedIsOwner = resolved.isOwner
        return try await CacheFirst.cacheFirst(
            type: .ledgerEntry,
            family: family,
            cacheService: cacheService,
            scope: resolvedScope,
            operations: .init(
                fetchCache: { [cacheService, profileName] familyName in
                    cacheService.fetchLedgerEntries(profileRecordName: profileName, family: familyName)
                },
                map: { [targetZoneID] cache in
                    cache.toLedgerEntry(zoneID: targetZoneID)
                },
                query: { [cloudKit, profile, targetZoneID, resolvedIsOwner] in
                    let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                    let predicate = NSPredicate(format: "profile == %@", profileRef as CVarArg)
                    let db = cloudKit.database(isOwner: resolvedIsOwner)
                    return try await cloudKit.query(LedgerEntry.self, predicate: predicate, in: targetZoneID, using: db)
                },
                hydrate: { [syncCoordinator, resolvedScope, targetZoneID] models in
                    await syncCoordinator.hydrationHandler.hydrateFromQuery(
                        models: models,
                        databaseScope: resolvedScope,
                        zoneID: targetZoneID
                    )
                },
                sortedBy: { $0.date > $1.date }
            )
        )
    }

    /// WHY derivation-only: payout math needs CloudKit reconciliation; UI balances use bucketBalances/totalBalance so tiles render instantly offline.
    func fetchLedgerEntries(profile: Profile, in dateRange: Range<Date>) async throws -> [LedgerEntry] {
        // WHY single zone: family zone owns scope so profile and family zones must agree.
        let targetZoneID = profile.family.recordID.zoneID
        assert(profile.id.zoneID == profile.family.recordID.zoneID)
        let profileName = profile.id.recordName
        let familyName = profile.family.recordID.recordName
        let family = Family(
            name: "",
            creatorUserRecordName: nil,
            id: CKRecord.ID(recordName: familyName, zoneID: targetZoneID)
        )
        guard let resolved = resolveLedgerScope(targetZoneID: targetZoneID, familyRecordName: familyName) else {
            // WHY cached-only: unknown scope never queries, but serves local cache.
            return cacheService.fetchLedgerEntries(profileRecordName: profileName, familyRecordName: familyName, start: dateRange.lowerBound, end: dateRange.upperBound)
                .map { [targetZoneID] cache in cache.toLedgerEntry(zoneID: targetZoneID) }
                .sorted { $0.date > $1.date }
        }
        let resolvedScope = resolved.scope
        let resolvedIsOwner = resolved.isOwner
        return try await CacheFirst.cacheFirst(
            type: .ledgerEntry,
            family: family,
            cacheService: cacheService,
            scope: resolvedScope,
            operations: .init(
                fetchCache: { [cacheService, profileName, dateRange] familyName in
                    cacheService.fetchLedgerEntries(profileRecordName: profileName, familyRecordName: familyName, start: dateRange.lowerBound, end: dateRange.upperBound)
                },
                map: { [targetZoneID] cache in
                    cache.toLedgerEntry(zoneID: targetZoneID)
                },
                query: { [cloudKit, profile, targetZoneID, dateRange, resolvedIsOwner] in
                    let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                    let predicate = NSPredicate(
                        format: "profile == %@ AND date >= %@ AND date < %@",
                        profileRef as CVarArg,
                        dateRange.lowerBound as CVarArg,
                        dateRange.upperBound as CVarArg
                    )
                    let db = cloudKit.database(isOwner: resolvedIsOwner)
                    return try await cloudKit.query(LedgerEntry.self, predicate: predicate, in: targetZoneID, using: db)
                },
                hydrate: { [syncCoordinator, resolvedScope, targetZoneID] models in
                    await syncCoordinator.hydrationHandler.hydrateFromQuery(
                        models: models,
                        databaseScope: resolvedScope,
                        zoneID: targetZoneID
                    )
                },
                sortedBy: { $0.date > $1.date }
            )
        )
    }

    /// WHY single scope: gate and hydrate share one resolved value; unknown rejects to cached-only instead of guessing.
    /// WHY zone match: caller zone must equal active zone so cross-zone reads cannot ride active scope.
    private func resolveLedgerScope(targetZoneID: CKRecordZone.ID, familyRecordName: String) -> (scope: CKDatabase.Scope, isOwner: Bool)? {
        do {
            try ActiveFamilyScopeGuard.requireActiveFamily(familyRecordName: familyRecordName, appState: appState)
        } catch {
            return nil
        }
        guard let activeZone = appState.familyZoneID ?? appState.family?.id.zoneID ?? appState.currentProfile?.id.zoneID, activeZone == targetZoneID else { return nil }
        // WHY single resolver: scope proves owner so gate, query, and hydrate cannot diverge on stored flag.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else { return nil }
        return (scope, scope == .private)
    }

    /// WHY derivation-only: history export reconciles against CloudKit; UI lists use cachedLedgerEntries so rows render instantly offline.
    func fetchTransactions(for profile: Profile,
                           in dateRange: DateInterval) async throws -> [LedgerEntry]
    {
        // WHY single zone: family zone owns scope so profile and family zones must agree.
        let targetZoneID = profile.family.recordID.zoneID
        assert(profile.id.zoneID == profile.family.recordID.zoneID)
        let profileName = profile.id.recordName
        let familyName = profile.family.recordID.recordName
        let family = Family(
            name: "",
            creatorUserRecordName: nil,
            id: CKRecord.ID(recordName: familyName, zoneID: targetZoneID)
        )
        guard let resolved = resolveLedgerScope(targetZoneID: targetZoneID, familyRecordName: familyName) else {
            // WHY cached-only: unknown scope never queries, but serves local cache.
            return cacheService.fetchLedgerEntries(profileRecordName: profileName, familyRecordName: familyName, start: dateRange.start, end: dateRange.end)
                .map { [targetZoneID] cache in cache.toLedgerEntry(zoneID: targetZoneID) }
                .sorted { $0.date > $1.date }
        }
        let resolvedScope = resolved.scope
        let resolvedIsOwner = resolved.isOwner
        // WHY indexed window: family+profile+date narrows via V10 composite index so history never scans.
        return try await CacheFirst.cacheFirst(
            type: .ledgerEntry,
            family: family,
            cacheService: cacheService,
            scope: resolvedScope,
            operations: .init(
                fetchCache: { [cacheService, profileName, dateRange] familyName in
                    cacheService.fetchLedgerEntries(profileRecordName: profileName, familyRecordName: familyName, start: dateRange.start, end: dateRange.end)
                },
                map: { [targetZoneID] cache in
                    cache.toLedgerEntry(zoneID: targetZoneID)
                },
                query: { [cloudKit, profile, targetZoneID, resolvedIsOwner] in
                    let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                    let predicate = NSPredicate(format: "profile == %@", profileRef as CVarArg)
                    let db = cloudKit.database(isOwner: resolvedIsOwner)
                    return try await cloudKit.query(
                        LedgerEntry.self,
                        predicate: predicate,
                        in: targetZoneID,
                        sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)],
                        using: db
                    )
                },
                hydrate: { [syncCoordinator, resolvedScope, targetZoneID] models in
                    await syncCoordinator.hydrationHandler.hydrateFromQuery(
                        models: models,
                        databaseScope: resolvedScope,
                        zoneID: targetZoneID
                    )
                },
                sortedBy: { $0.date > $1.date }
            )
        )
    }

    // MARK: - Balances

    /// WHY derivation-only: payout verification reconciles against CloudKit; UI balances use bucketBalances/totalBalance so tiles render instantly offline.
    func currentBalance(for profile: Profile) async throws -> Int64 {
        let ledgerEntries = try await fetchAllLedgerEntries(profile: profile)
        // WHY single-count: goal entries reuse counted funds and transfers net to zero across buckets.
        return ledgerEntries.filter { BucketService.isCounted($0) }.reduce(0) { $0 + $1.amount }
    }

    /// WHY cache-only: tiles and rings render from SwiftData with zero CloudKit wait.
    func bucketBalances(profileRecordName: String, familyRecordName: String) -> [BucketKind: Int64] {
        let entries = cacheService.fetchLedgerEntries(
            profileRecordName: profileRecordName,
            family: familyRecordName
        )
        return BucketService.bucketBalances(for: entries, profileRecordName: profileRecordName)
    }

    /// WHY cache-only: labels sum cached buckets with zero CloudKit wait.
    func totalBalance(profileRecordName: String, familyRecordName: String) -> Int64 {
        BucketService.totalBalance(bucketBalances: bucketBalances(profileRecordName: profileRecordName, familyRecordName: familyRecordName))
    }

    // MARK: - Deterministic Identity

    // WHY: deterministicRecordName must produce the same CKRecord.ID on every
    // device for identical payloads so CloudKit dedupes money movements.
    // All discriminating fields must be folded into the hash — never a random UUID.
    private func deterministicRecordName(source: String, profile: Profile, family: Family, amount: Int64, description: String, location _: String?, date: Date) -> String {
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        let cents = Int64(clamping: amount.magnitude)
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // WHY legacy base: trimmed-only hash keeps historic rows matching so re-mints dedupe.
        let hashInput = trimmed
        let digest = SHA256.hash(data: Data(hashInput.utf8))
        let value = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let descHash = value % 10000
        return "\(source)-\(profile.id.recordName)-\(family.id.recordName)-\(ms)-\(cents)-\(descHash)"
    }

    private func validateScopeAllowingNewHero(family: Family) throws {
        // WHY fail-closed: scope mismatch denies rather than downgrading to family-only.
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(family: family, cloudKit: cloudKit, appState: appState)
    }

    // WHY: CloudKit dedupe requires deterministic IDs. A random UUID escape hatch
    // would create divergent recordNames for the same logical entry across
    // devices, defeating idempotency. On payload collision at the same base
    // name, extend deterministically so every device converges on the same
    // alternate name instead of forking.
    // WHY fail-closed amount: every discriminating field folds into the match
    // so hash-colliding payloads cannot dedupe; split waterfall legs share the
    // request-convergent base and prove completeness via leg-sum verification
    // in waterfallDebit instead of relying on this single-row check alone.
    private func makeLedgerID(source: String, profile: Profile, family: Family, amount: Int64, description: String, location: String?, date: Date) -> CKRecord.ID {
        let base = deterministicRecordName(source: source, profile: profile, family: family, amount: amount, description: description, location: location, date: date)
        var recordName = base
        var attempt = 0
        while let existing = cacheService.fetchLedgerEntry(recordName: recordName, family: family.id.recordName) {
            guard existing.source != source
                || existing.entryDescription != description
                || !DeterministicRecordID.isSameMillisecond(existing.date, date)
                || existing.location != location
                || existing.amount != amount
            else {
                break
            }
            // WHY: Extend deterministically — hash all discriminating fields so
            // same divergent payload yields same recordName on any device.
            // Payload must include every field that participates in base-record
            // collisions (description + ms) so hash-colliding descriptions cannot
            // still collide after the suffix.
            let ms = Int64(date.timeIntervalSince1970 * 1000)
            let cents = Int64(clamping: amount.magnitude)
            let normalizedLocation = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let trimmedLower = description.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // WHY unbounded convergent extension: every attempt hashes full payload so all devices agree on each fallback name.
            let payload = "\(trimmedLower)|\(ms)|\(cents)|\(normalizedLocation)|\(source)|\(attempt)"
            recordName = DeterministicRecordID.collisionExtendedName(base: base, payload: payload, date: date)
            attempt += 1
        }
        return CKRecord.ID(recordName: recordName, zoneID: family.id.zoneID)
    }

    /// Bounded cash-debit inputs keeping deterministic IDs convergent.
    private struct ValidatedCashDebitInputs {
        let request: Int64
        let trimmedDesc: String
        let normalizedLocation: String?
        let effectiveDate: Date
    }

    /// WHY fail-closed bounds: overlong text and far-future dates reject instead of silently rewriting user intent.
    private func validatedCashDebitInputs(description: String, location: String?, date: Date, amount: Int64) throws -> ValidatedCashDebitInputs {
        guard (1 ... 100_000_000).contains(amount) else {
            throw SpendingServiceError.invalidAmount
        }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 120).contains(trimmed.count) else {
            throw SpendingServiceError.invalidAmount
        }
        let trimmedDesc = trimmed
        let rawLocation = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard rawLocation.count <= 80 else {
            throw SpendingServiceError.invalidAmount
        }
        let normalizedLocation: String? = rawLocation.isEmpty ? nil : rawLocation
        // WHY fail-closed date: far-future timestamps reject so deterministic IDs never silently shift.
        let cap = Date().addingTimeInterval(300)
        guard date <= cap else {
            throw SpendingServiceError.invalidAmount
        }
        let effectiveDate = date
        return ValidatedCashDebitInputs(request: amount, trimmedDesc: trimmedDesc, normalizedLocation: normalizedLocation, effectiveDate: effectiveDate)
    }

    /// WHY converge on replay: a first run may leave legs without goal drawdown, so replays refill the gap idempotently.
    func isMatchingWaterfallBase(_ entry: LedgerEntryCache, source: String, description: String, location: String?, date: Date) -> Bool {
        entry.source == source
            && entry.entryDescription == description
            && DeterministicRecordID.isSameMillisecond(entry.date, date)
            && entry.location == location
            && entry.bucketKind == BucketKind.spend.rawValue
    }

    func isMatchingWaterfallShort(_ entry: LedgerEntryCache, source: String, description: String, location: String?, date: Date) -> Bool {
        entry.source == source
            && entry.entryDescription == description
            && DeterministicRecordID.isSameMillisecond(entry.date, date)
            && entry.location == location
            && entry.bucketKind == BucketKind.shortTermSave.rawValue
    }

    /// WHY fork-aware resolve: collision forks append hex-msSuffix before or after `-shortcover`, so exact fetch alone misses extended Short legs.
    func resolveWaterfallBase(
        requestBaseName: String,
        profileRecordName: String,
        familyName: String,
        source: String,
        description: String,
        location: String?,
        date: Date
    ) -> LedgerEntryCache? {
        if let exact = cacheService.fetchLedgerEntry(recordName: requestBaseName, family: familyName),
           isMatchingWaterfallBase(exact, source: source, description: description, location: location, date: date)
        {
            return exact
        }
        let targetBase = waterfallDeleteBase(requestBaseName)
        let siblings = cacheService.fetchLedgerEntries(profileRecordName: profileRecordName, family: familyName, recordNamePrefix: requestBaseName)
        return siblings
            .filter {
                !isShortcoverName($0.recordName)
                    && waterfallDeleteBase($0.recordName) == targetBase
                    && isMatchingWaterfallBase($0, source: source, description: description, location: location, date: date)
            }
            .sorted { $0.recordName < $1.recordName }
            .first
    }

    /// WHY fork-aware resolve: shortcover forks live at `base-hex-msSuffix-shortcover` or `base-shortcover-hex-msSuffix`, so prefix search converges both shapes.
    func resolveWaterfallShort(
        requestBaseName: String,
        requestShortName: String,
        profileRecordName: String,
        familyName: String,
        source: String,
        description: String,
        location: String?,
        date: Date
    ) -> LedgerEntryCache? {
        if let exact = cacheService.fetchLedgerEntry(recordName: requestShortName, family: familyName),
           isMatchingWaterfallShort(exact, source: source, description: description, location: location, date: date)
        {
            return exact
        }
        let tailed = cacheService.fetchLedgerEntries(profileRecordName: profileRecordName, family: familyName, recordNamePrefix: "\(requestShortName)-")
        if let hit = tailed
            .filter({ isMatchingWaterfallShort($0, source: source, description: description, location: location, date: date) })
            .sorted(by: { $0.recordName < $1.recordName })
            .first
        {
            return hit
        }
        let targetBase = waterfallDeleteBase(requestBaseName)
        let siblings = cacheService.fetchLedgerEntries(profileRecordName: profileRecordName, family: familyName, recordNamePrefix: requestBaseName)
        return siblings
            .filter {
                isShortcoverName($0.recordName)
                    && waterfallDeleteBase($0.recordName) == targetBase
                    && isMatchingWaterfallShort($0, source: source, description: description, location: location, date: date)
            }
            .sorted { $0.recordName < $1.recordName }
            .first
    }

    /// WHY converge on replay: a first run may leave legs without goal drawdown, so replays refill the gap idempotently.
    private func ensureShortfallDrawdown(
        shortcoverName: String,
        requestBaseName: String,
        profile: Profile,
        family: Family,
        source: String,
        description: String,
        location: String?,
        effectiveDate: Date
    ) async throws {
        guard let shortcover = resolveWaterfallShort(
            requestBaseName: requestBaseName,
            requestShortName: shortcoverName,
            profileRecordName: profile.id.recordName,
            familyName: family.id.recordName,
            source: source,
            description: description,
            location: location,
            date: effectiveDate
        ) else { return }
        let resolvedName = shortcover.recordName
        let drawn = -shortcover.amount
        guard drawn > 0 else { return }
        // WHY fail-closed drawdown: every Short decrease unwinds goal markers so progress never stays inflated.
        let goalService = GoalService(
            cloudKit: cloudKit,
            cacheService: cacheService,
            appState: appState,
            syncCoordinator: syncCoordinator
        )
        _ = try await goalService.applyDrawdown(
            amountPennies: drawn,
            profile: profile,
            family: family,
            bucketKind: .shortTermSave,
            sourceEventID: resolvedName,
            contributionDate: effectiveDate
        )
    }

    /// WHY single query: nine waterfall fields exceed the lint parameter limit, so one value keeps replay convergent.
    struct WaterfallReplayQuery {
        let baseName: String
        let shortName: String
        let source: String
        let description: String
        let location: String?
        let date: Date
        let request: Int64
        let familyName: String
        let profileRecordName: String
    }

    /// WHY single waterfall: Spend covers first, Short covers the shortfall with goal drawdown, Long never auto-debits.
    /// WHY shared request base: Spend leg lives at the request-convergent base, Short leg at base-shortcover
    /// (plus deterministic hex-msSuffix forks on collision) so grouped ledger strips suffixes to one receipt.
    private func verifiedWaterfallReplay(_ query: WaterfallReplayQuery) -> LedgerEntryCache? {
        let base = resolveWaterfallBase(
            requestBaseName: query.baseName,
            profileRecordName: query.profileRecordName,
            familyName: query.familyName,
            source: query.source,
            description: query.description,
            location: query.location,
            date: query.date
        )
        let short = resolveWaterfallShort(
            requestBaseName: query.baseName,
            requestShortName: query.shortName,
            profileRecordName: query.profileRecordName,
            familyName: query.familyName,
            source: query.source,
            description: query.description,
            location: query.location,
            date: query.date
        )
        guard base != nil || short != nil else { return nil }
        // WHY sum check: stored amounts are negative debits; only an exact sum replays so partial legs cannot masquerade as full debits.
        let storedTotal = -(base?.amount ?? 0) + -(short?.amount ?? 0)
        guard storedTotal == query.request else { return nil }
        return base ?? short
    }

    private func waterfallDebit(source: String,
                                profile: Profile,
                                family: Family,
                                request: Int64,
                                trimmedDesc: String,
                                normalizedLocation: String?,
                                effectiveDate: Date,
                                enqueueContext: String) async throws -> LedgerEntry
    {
        let familyName = family.id.recordName
        let zoneID = family.id.zoneID
        // WHY request-convergent lookup: replay names derive from the request alone so balance shifts after the first mint cannot fork a duplicate.
        let requestBaseName = deterministicRecordName(
            source: source,
            profile: profile,
            family: family,
            amount: -request,
            description: trimmedDesc,
            location: normalizedLocation,
            date: effectiveDate
        )
        let requestShortName = "\(requestBaseName)-shortcover"
        // WHY replay-first: identical payloads converge to the stored rows instead of debiting twice.
        if let hit = verifiedWaterfallReplay(
            WaterfallReplayQuery(
                baseName: requestBaseName,
                shortName: requestShortName,
                source: source,
                description: trimmedDesc,
                location: normalizedLocation,
                date: effectiveDate,
                request: request,
                familyName: familyName,
                profileRecordName: profile.id.recordName
            )
        ) {
            // WHY fail-closed replay: a missing drawdown still throws so goal progress never stays inflated.
            try await ensureShortfallDrawdown(
                shortcoverName: requestShortName,
                requestBaseName: requestBaseName,
                profile: profile,
                family: family,
                source: source,
                description: trimmedDesc,
                location: normalizedLocation,
                effectiveDate: effectiveDate
            )
            return hit.toLedgerEntry(zoneID: zoneID)
        }
        let baseID = makeLedgerID(
            source: source,
            profile: profile,
            family: family,
            amount: -request,
            description: trimmedDesc,
            location: normalizedLocation,
            date: effectiveDate
        )
        if baseID.recordName != requestBaseName,
           let forkHit = verifiedWaterfallReplay(
               WaterfallReplayQuery(
                   baseName: baseID.recordName,
                   shortName: "\(baseID.recordName)-shortcover",
                   source: source,
                   description: trimmedDesc,
                   location: normalizedLocation,
                   date: effectiveDate,
                   request: request,
                   familyName: familyName,
                   profileRecordName: profile.id.recordName
               )
           )
        {
            // WHY fail-closed replay: a missing drawdown still throws so goal progress never stays inflated.
            try await ensureShortfallDrawdown(
                shortcoverName: "\(baseID.recordName)-shortcover",
                requestBaseName: baseID.recordName,
                profile: profile,
                family: family,
                source: source,
                description: trimmedDesc,
                location: normalizedLocation,
                effectiveDate: effectiveDate
            )
            return forkHit.toLedgerEntry(zoneID: zoneID)
        }
        let inputs = WaterfallInputs(
            source: source,
            profile: profile,
            family: family,
            request: request,
            trimmedDesc: trimmedDesc,
            normalizedLocation: normalizedLocation,
            effectiveDate: effectiveDate,
            enqueueContext: enqueueContext
        )
        if let gapHit = try await waterfallGapFill(
            inputs: inputs,
            requestBaseName: requestBaseName,
            requestShortName: requestShortName,
            familyName: familyName,
            zoneID: zoneID
        ) {
            return gapHit
        }
        return try await mintWaterfallLegs(
            inputs: inputs,
            baseID: baseID,
            familyName: familyName,
            zoneID: zoneID
        )
    }

    // MARK: - Mutations (local-first)

    func logManual(profile: Profile,
                   family: Family,
                   familyRecordName: String,
                   description: String,
                   amount: Int64,
                   location: String? = nil,
                   date: Date = Date()) async throws -> LedgerEntry
    {
        guard familyRecordName == family.id.recordName else {
            throw ScopeViolation.familyMismatch(active: family.id.recordName, supplied: familyRecordName)
        }
        guard let acting = appState.currentProfile, acting.id == profile.id || acting.role.isParent else {
            throw FamilyServiceError.unauthorized
        }
        try validateScopeAllowingNewHero(family: family)

        // WHY single waterfall: manual spends and withdrawals share one debit path so bucket splits cannot drift.
        let inputs = try validatedCashDebitInputs(description: description, location: location, date: date, amount: amount)
        return try await waterfallDebit(
            source: LedgerSource.manual.rawValue,
            profile: profile,
            family: family,
            request: inputs.request,
            trimmedDesc: inputs.trimmedDesc,
            normalizedLocation: inputs.normalizedLocation,
            effectiveDate: inputs.effectiveDate,
            enqueueContext: "LedgerService.logManual"
        )
    }

    /// Mints one ledger entry per bucket share; the returned array sums to the full deposit total.
    func depositEntries(profile: Profile,
                        family: Family,
                        familyRecordName: String,
                        description: String,
                        amount: Int64,
                        location: String? = nil,
                        date: Date = Date()) async throws -> [LedgerEntry]
    {
        guard familyRecordName == family.id.recordName else {
            throw ScopeViolation.familyMismatch(active: family.id.recordName, supplied: familyRecordName)
        }
        guard let acting = appState.currentProfile, acting.role.isParent else {
            throw FamilyServiceError.unauthorized
        }
        try validateScopeAllowingNewHero(family: family)

        // WHY fail-closed bounds: deposit shares the same 1..100M amount, 1..120 description,
        // 0..80 location, and sub-300s date discipline as manual debits so IDs stay convergent.
        guard (1 ... 100_000_000).contains(amount) else {
            throw SpendingServiceError.invalidAmount
        }

        let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 120).contains(trimmedDesc.count) else {
            throw SpendingServiceError.invalidAmount
        }

        let rawDepositLocation = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard rawDepositLocation.count <= 80 else {
            throw SpendingServiceError.invalidAmount
        }
        let normalizedLocation: String? = rawDepositLocation.isEmpty ? nil : rawDepositLocation
        let dateCap = Date().addingTimeInterval(300)
        guard date <= dateCap else {
            throw SpendingServiceError.invalidAmount
        }
        let effectiveDate = date

        // WHY: whole-penny math keeps bucket shares summing to the exact deposit
        // total regardless of how percentages round.
        // WHY clamp: magnitude is UInt64 so clamp keeps splitPennies on Int64 canon.
        let totalPennies = Int64(clamping: amount.magnitude)
        guard totalPennies > 0 else {
            throw SpendingServiceError.invalidAmount
        }
        // WHY split steps: separate split from filter so checker stays fast.
        let allShares = BucketService.splitPennies(totalPennies, profile: profile)
        let shares = allShares.filter { $0.pennies > 0 }
        guard !shares.isEmpty else {
            throw SpendingServiceError.invalidAmount
        }

        let depositSource = LedgerSource.deposit.rawValue
        let base = deterministicRecordName(
            source: depositSource,
            profile: profile,
            family: family,
            amount: amount,
            description: trimmedDesc,
            location: normalizedLocation,
            date: effectiveDate
        )

        var entries: [LedgerEntry] = []
        entries.reserveCapacity(shares.count)
        for share in shares {
            let isSingle = shares.count == 1
            let candidate = isSingle ? base : "\(base)-\(share.kind.rawValue)"
            let bucketSuffix = isSingle ? "" : " · \(share.kind.displayName)"
            let shareDescription = "\(trimmedDesc)\(bucketSuffix)"
            let shareAmount = share.pennies
            var recordName = candidate
            if let existing = cacheService.fetchLedgerEntry(recordName: candidate, family: family.id.recordName),
               existing.source != depositSource
               || existing.entryDescription != shareDescription
               || !DeterministicRecordID.isSameMillisecond(existing.date, effectiveDate)
               || existing.location != normalizedLocation
               || existing.amount != share.pennies
            {
                // WHY: extend deterministically so same divergent payload yields
                // same recordName on any device, never a random UUID.
                let ms = Int64(effectiveDate.timeIntervalSince1970 * 1000)
                let trimmedLower = trimmedDesc.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let locationPart = normalizedLocation ?? ""
                let payload = "\(trimmedLower)|\(ms)|\(share.pennies)|\(locationPart)|\(depositSource)|\(share.kind.rawValue)"
                recordName = DeterministicRecordID.collisionExtendedName(base: candidate, payload: payload, date: effectiveDate)
            }
            let entry = LedgerEntry(
                profile: CKRecord.Reference(recordID: profile.id, action: .none),
                amount: shareAmount,
                description: shareDescription,
                location: normalizedLocation,
                date: effectiveDate,
                source: depositSource,
                bucketKind: share.kind.rawValue,
                family: CKRecord.Reference(recordID: family.id, action: .none),
                id: CKRecord.ID(recordName: recordName, zoneID: family.id.zoneID)
            )
            entries.append(entry)
        }

        for entry in entries {
            await cacheService.upsertLedgerEntry(entry)
        }
        ActiveFamilyScopeGuard.batchEnqueueWithCorrectedOwner(syncCoordinator, ids: entries.map(\.id), appState: appState, logger: logger, context: "LedgerService.deposit")
        Task { [weak self] in await self?.syncCoordinator.sendPendingChanges() }

        // WHY: save-bucket portions cascade into FIFO goals so bucket totals and
        // goal progress stay consistent; surplus past all goals rests in the bucket.
        // WHY split filter: single-predicate filters keep checker fast.
        let shortShares = shares.filter { $0.kind == .shortTermSave }
        let longShares = shares.filter { $0.kind == .longTermSave }
        let saveShares = shortShares + longShares
        if !saveShares.isEmpty {
            let goalService = GoalService(
                cloudKit: cloudKit,
                cacheService: cacheService,
                appState: appState,
                syncCoordinator: syncCoordinator
            )
            for share in saveShares {
                do {
                    _ = try await goalService.contributeToBucket(
                        amountPennies: share.pennies,
                        profile: profile,
                        family: family,
                        bucketKind: share.kind,
                        sourceEventID: base,
                        contributionDate: effectiveDate
                    )
                } catch {
                    logger.warning("Goal allocation failed for deposit \(base, privacy: .private): \(error, privacy: .private)")
                }
            }
        }

        guard !entries.isEmpty else {
            throw SpendingServiceError.persistenceFailed
        }
        return entries
    }

    func withdraw(profile: Profile,
                  family: Family,
                  familyRecordName: String,
                  description: String,
                  amount: Int64,
                  location: String? = nil,
                  date: Date = Date()) async throws -> LedgerEntry
    {
        guard familyRecordName == family.id.recordName else {
            throw ScopeViolation.familyMismatch(active: family.id.recordName, supplied: familyRecordName)
        }
        guard let acting = appState.currentProfile, acting.role.isParent else {
            throw FamilyServiceError.unauthorized
        }
        try validateScopeAllowingNewHero(family: family)

        // WHY single waterfall: manual spends and withdrawals share one debit path so bucket splits cannot drift.
        let inputs = try validatedCashDebitInputs(description: description, location: location, date: date, amount: amount)
        return try await waterfallDebit(
            source: LedgerSource.withdrawal.rawValue,
            profile: profile,
            family: family,
            request: inputs.request,
            trimmedDesc: inputs.trimmedDesc,
            normalizedLocation: inputs.normalizedLocation,
            effectiveDate: inputs.effectiveDate,
            enqueueContext: "LedgerService.withdraw"
        )
    }

    func delete(_ entry: LedgerEntry) async throws {
        guard entry.sourceEnum != .quest else {
            throw SpendingServiceError.unsupported
        }

        guard let acting = appState.currentProfile,
              entry.profile.recordID == acting.id || acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }

        try ActiveFamilyScopeGuard.requireActiveFamily(familyRef: entry.family, appState: appState)

        // WHY atomic waterfall: Spend/shortcover legs share one receipt, so deleting one leg alone would orphan its sibling plus drawdown markers.
        let targets = waterfallDeleteTargets(for: entry)
        for target in targets {
            // WHY single step: tombstone is captured inside the helper so the delete survives row removal.
            await ActiveFamilyScopeGuard.deleteAndEnqueue(
                cacheService: cacheService,
                target: target,
                type: .ledgerEntry,
                deleteContext: .init(
                    coordinator: syncCoordinator,
                    appState: appState,
                    logger: logger,
                    context: "LedgerService.delete",
                    expectedActiveZone: appState.familyZoneID
                )
            )
        }
    }

    // MARK: - Generic Persistence

    func persist(_ entry: LedgerEntry, context: String) async {
        await cacheService.upsertLedgerEntry(entry)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: entry.id, appState: appState, logger: logger, context: context)
        Task { [weak self] in await self?.syncCoordinator.sendPendingChanges() }
    }

    func persist(_ entries: [LedgerEntry], context: String) async {
        for entry in entries {
            await cacheService.upsertLedgerEntry(entry)
        }
        ActiveFamilyScopeGuard.batchEnqueueWithCorrectedOwner(syncCoordinator, ids: entries.map(\.id), appState: appState, logger: logger, context: context)
        Task { [weak self] in await self?.syncCoordinator.sendPendingChanges() }
    }
}
