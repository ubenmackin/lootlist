//
//  SpendingService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import CryptoKit
import Foundation
import os

enum SpendingServiceError: Error, LocalizedError, Equatable, Sendable {
    case unsupported
    case invalidAmount
    case persistenceFailed
    case duplicate
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: "This action isn't supported on this device."
        case .invalidAmount: "Enter a valid positive amount."
        case .persistenceFailed: "Could not save your spending. Please try again."
        case .duplicate: "An entry with these details already exists. Edit the description to save a distinct entry."
        case .underlying: "Something went wrong. Please try again."
        }
    }
}

@MainActor
@Observable
class SpendingService {
    private let cloudKit: any CloudKitServiceProtocol
    let cacheService: any CacheServicing
    let syncCoordinator: any SyncEnqueuing

    var toastManager: ToastManager?

    let appState: AppState

    private static let staticLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "ManualSpending")
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "ManualSpending")

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
        cacheService: (any CacheServicing)? = nil,
        appState: AppState? = nil,
        syncCoordinator: (any SyncEnqueuing)? = nil
    ) {
        let cache: any CacheServicing
        if let cacheService {
            cache = cacheService
        } else {
            Self.staticLogger.warning("SpendingService initialized without cacheService; using fallback in-memory cache.")
            cache = CacheService.inMemoryFallback(logger: Self.staticLogger)
        }
        let state = appState ?? AppState()
        let coord: any SyncEnqueuing
        if let syncCoordinator {
            coord = syncCoordinator
        } else if let ck = cloudKit as? CloudKitService {
            // WHY: delegate stack still needs the concrete cache for hydration;
            // reuse the injected cache when it is concrete so reads and writes share one store.
            let concreteCache = cache as? CacheService ?? CacheService.inMemoryFallback(logger: Self.staticLogger)
            let delegate = CKSyncEngineDelegateHandler(
                backgroundCache: nil,
                conflictResolver: CKSyncConflictResolver(cacheService: concreteCache, backgroundCache: nil, toastManager: nil, appState: state),
                cacheService: concreteCache,
                appState: state
            )
            coord = CKSyncEngineCoordinator(cloudKitService: ck, delegateHandler: delegate, appState: state)
        } else {
            coord = NoopSyncEnqueuing()
        }
        self.init(cloudKit: cloudKit, cacheService: cache, appState: state, syncCoordinator: coord)
    }

    func isAvailable() -> Bool {
        true
    }

    // MARK: - Fetch

    func fetchTransactions(for profile: Profile,
                           in dateRange: DateInterval) async throws -> [LedgerEntry]
    {
        let targetZoneID = profile.family.recordID.zoneID
        let profileName = profile.id.recordName
        let familyName = profile.family.recordID.recordName
        let family = Family(
            name: "",
            createdBy: profile.family.recordID,
            id: CKRecord.ID(recordName: familyName, zoneID: targetZoneID)
        )
        let isOwner = targetZoneID.ownerName == CKCurrentUserDefaultName || (ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) && appState.familyZoneID == targetZoneID)
        let scopeForHydrate: CKDatabase.Scope = DatabaseScopeResolver.scope(isOwner: isOwner)
        // WHY: dateRange filtering is applied once in fetchCache. The previous
        // post-filter `result.filter { dateRange.contains($0.date) }` was a
        // redundant second pass over the same bounded set (cached path and
        // stale-network fallback both already filter in fetchCache); keeping a
        // single filter preserves sort order without double iteration.
        return try await CacheFirst.cacheFirst(
            type: .ledgerEntry,
            family: family,
            cacheService: cacheService,
            appState: appState,
            fetchCache: { [cacheService, profileName, dateRange] familyName in
                cacheService.fetchLedgerEntries(profileRecordName: profileName, family: familyName)
                    .filter { dateRange.contains($0.date) }
            },
            map: { [targetZoneID] cache in
                cache.toLedgerEntry(zoneID: targetZoneID)
            },
            query: { [cloudKit, profile, targetZoneID, isOwner] in
                let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                let predicate = NSPredicate(format: "profile == %@", profileRef as CVarArg)
                let db = cloudKit.database(isOwner: isOwner)
                return try await cloudKit.query(
                    LedgerEntry.self,
                    predicate: predicate,
                    in: targetZoneID,
                    sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)],
                    using: db
                )
            },
            hydrate: { [syncCoordinator, scopeForHydrate, targetZoneID] models in
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: models,
                    databaseScope: scopeForHydrate,
                    zoneID: targetZoneID
                )
            },
            sortedBy: { $0.date > $1.date }
        )
    }

    // MARK: - Helpers

    // WHY: deterministicRecordName must produce the same CKRecord.ID on every
    // device for identical payloads so CloudKit dedupes money movements.
    // All discriminating fields must be folded into the hash — never a random UUID.
    private func deterministicRecordName(source: String, profile: Profile, family: Family, amount: Double, description: String, date: Date) -> String {
        let ms = Int(date.timeIntervalSince1970 * 1000)
        let cents = Int((abs(amount) * 100).rounded())
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let value = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let descHash = value % 10000
        return "\(source)-\(profile.id.recordName)-\(family.id.recordName)-\(ms)-\(cents)-\(descHash)"
    }

    // WHY: CloudKit/cache round-trips quantize dates, so exact Date equality
    // forks deterministic names for the same logical instant.
    private func isSameMillisecond(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) < 0.001
    }

    // WHY: collision suffixes must converge cross-device, so one helper owns
    // the hex+msSuffix extension instead of duplicated inline blocks.
    private func extendedRecordName(base: String, payload: String, date: Date) -> String {
        let ms = Int(date.timeIntervalSince1970 * 1000)
        let hash = SHA256.hash(data: Data(payload.utf8))
        let hex = hash.prefix(4).map { String(format: "%02x", $0) }.joined()
        let msSuffix = ms % 1000
        return "\(base)-\(hex)-\(msSuffix)"
    }

    private func validateScopeAllowingNewHero(family: Family) throws {
        do {
            try ActiveFamilyScopeGuard.requireActiveFamilyScope(family: family, cloudKit: cloudKit, appState: appState)
        } catch {
            logger.warning("Strict scope check failed, falling back to family-only check: \(error, privacy: .private)")
            try ActiveFamilyScopeGuard.requireActiveFamily(familyRecordName: family.id.recordName, appState: appState)
        }
    }

    // WHY: CloudKit dedupe requires deterministic IDs. A random UUID escape hatch
    // would create divergent recordNames for the same logical entry across
    // devices, defeating idempotency. On payload collision at the same base
    // name, extend deterministically so every device converges on the same
    // alternate name instead of forking.
    private func makeLedgerID(source: String, profile: Profile, family: Family, amount: Double, description: String, location: String?, date: Date) -> CKRecord.ID {
        let base = deterministicRecordName(source: source, profile: profile, family: family, amount: amount, description: description, date: date)
        var recordName = base
        if let existing = cacheService.fetchLedgerEntry(recordName: base, family: family.id.recordName),
           existing.source != source
           || existing.entryDescription != description
           || !isSameMillisecond(existing.date, date)
           || existing.location != location
           || Int((abs(existing.amount) * 100).rounded()) != Int((abs(amount) * 100).rounded())
        {
            // WHY: Extend deterministically — hash all discriminating fields so
            // same divergent payload yields same recordName on any device.
            // Payload must include every field that participates in base-record
            // collisions (description + ms) so hash-colliding descriptions cannot
            // still collide after the suffix.
            let ms = Int(date.timeIntervalSince1970 * 1000)
            let cents = Int((abs(amount) * 100).rounded())
            let normalizedLocation = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let trimmedLower = description.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let payload = "\(trimmedLower)|\(ms)|\(cents)|\(normalizedLocation)|\(source)"
            recordName = extendedRecordName(base: base, payload: payload, date: date)
        }
        return CKRecord.ID(recordName: recordName, zoneID: family.id.zoneID)
    }

    // MARK: - Mutations (local-first)

    func logManual(profile: Profile,
                   family: Family,
                   familyRecordName: String,
                   description: String,
                   amount: Double,
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

        guard amount.isFinite, amount > 0 else {
            throw SpendingServiceError.invalidAmount
        }

        let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDesc.isEmpty else {
            throw SpendingServiceError.invalidAmount
        }

        // WHY: manual spends debit the spend bucket so BucketService.applyBucketAttribution
        // keeps bucket balances consistent with the ledger total.
        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            amount: -abs(amount),
            description: trimmedDesc,
            location: location?.trimmingCharacters(in: .whitespacesAndNewlines),
            date: date,
            source: LedgerSource.manual.rawValue,
            bucketKind: BucketKind.spend.rawValue,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: makeLedgerID(
                source: LedgerSource.manual.rawValue,
                profile: profile,
                family: family,
                amount: amount,
                description: trimmedDesc,
                location: location?.trimmingCharacters(in: .whitespacesAndNewlines),
                date: date
            )
        )

        await cacheService.upsertLedgerEntry(entry)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: entry.id, appState: appState, logger: logger, context: "SpendingService.logSpending")
        return entry
    }

    /// Mints one ledger entry per bucket share; the returned array sums to the full deposit total.
    func depositEntries(profile: Profile,
                        family: Family,
                        familyRecordName: String,
                        description: String,
                        amount: Double,
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

        guard amount.isFinite, amount > 0 else {
            throw SpendingServiceError.invalidAmount
        }

        let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDesc.isEmpty else {
            throw SpendingServiceError.invalidAmount
        }

        // WHY: whole-penny math keeps bucket shares summing to the exact deposit
        // total regardless of how percentages round.
        let totalPennies = Int((abs(amount) * 100).rounded())
        guard totalPennies > 0 else {
            throw SpendingServiceError.invalidAmount
        }
        let shares = BucketService.splitPennies(totalPennies, profile: profile)
            .filter { $0.pennies > 0 }
        guard !shares.isEmpty else {
            throw SpendingServiceError.invalidAmount
        }

        let depositSource = LedgerSource.deposit.rawValue
        let normalizedLocation = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = deterministicRecordName(
            source: depositSource,
            profile: profile,
            family: family,
            amount: amount,
            description: trimmedDesc,
            date: date
        )

        var entries: [LedgerEntry] = []
        entries.reserveCapacity(shares.count)
        for share in shares {
            let isSingle = shares.count == 1
            let candidate = isSingle ? base : "\(base)-\(share.kind.rawValue)"
            let bucketSuffix = isSingle ? "" : " · \(share.kind.displayName)"
            let shareDescription = "\(trimmedDesc)\(bucketSuffix)"
            let shareAmount = Double(share.pennies) / 100.0
            var recordName = candidate
            if let existing = cacheService.fetchLedgerEntry(recordName: candidate, family: family.id.recordName),
               existing.source != depositSource
               || existing.entryDescription != shareDescription
               || !isSameMillisecond(existing.date, date)
               || existing.location != normalizedLocation
               || Int((abs(existing.amount) * 100).rounded()) != share.pennies
            {
                // WHY: extend deterministically so same divergent payload yields
                // same recordName on any device, never a random UUID.
                let ms = Int(date.timeIntervalSince1970 * 1000)
                let trimmedLower = trimmedDesc.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let locationPart = normalizedLocation ?? ""
                let payload = "\(trimmedLower)|\(ms)|\(share.pennies)|\(locationPart)|\(depositSource)|\(share.kind.rawValue)"
                recordName = extendedRecordName(base: candidate, payload: payload, date: date)
            }
            let entry = LedgerEntry(
                profile: CKRecord.Reference(recordID: profile.id, action: .none),
                amount: shareAmount,
                description: shareDescription,
                location: normalizedLocation,
                date: date,
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
        ActiveFamilyScopeGuard.batchEnqueueWithCorrectedOwner(syncCoordinator, ids: entries.map(\.id), appState: appState, logger: logger, context: "SpendingService.deposit")

        // WHY: save-bucket portions cascade into FIFO goals so bucket totals and
        // goal progress stay consistent; surplus past all goals rests in the bucket.
        let saveShares = shares.filter { $0.kind == .shortTermSave || $0.kind == .longTermSave }
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
                        amountPennies: Int64(share.pennies),
                        profile: profile,
                        family: family,
                        bucketKind: share.kind,
                        sourceEventID: base,
                        contributionDate: date
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

    /// Deprecated: persists the full split via `depositEntries` but returns the first share only.
    @available(*, deprecated, message: "Use depositEntries and sum amounts; deposit returns only the first share when the split yields multiple entries.")
    func deposit(profile: Profile,
                 family: Family,
                 familyRecordName: String,
                 description: String,
                 amount: Double,
                 location: String? = nil,
                 date: Date = Date()) async throws -> LedgerEntry
    {
        let entries = try await depositEntries(
            profile: profile,
            family: family,
            familyRecordName: familyRecordName,
            description: description,
            amount: amount,
            location: location,
            date: date
        )
        guard let first = entries.first else {
            throw SpendingServiceError.persistenceFailed
        }
        return first
    }

    func withdraw(profile: Profile,
                  family: Family,
                  familyRecordName: String,
                  description: String,
                  amount: Double,
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

        guard amount.isFinite, amount > 0 else {
            throw SpendingServiceError.invalidAmount
        }

        let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDesc.isEmpty else {
            throw SpendingServiceError.invalidAmount
        }

        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            amount: -abs(amount),
            description: trimmedDesc,
            location: location?.trimmingCharacters(in: .whitespacesAndNewlines),
            date: date,
            source: LedgerSource.withdrawal.rawValue,
            bucketKind: BucketKind.spend.rawValue,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: makeLedgerID(
                source: LedgerSource.withdrawal.rawValue,
                profile: profile,
                family: family,
                amount: amount,
                description: trimmedDesc,
                location: location?.trimmingCharacters(in: .whitespacesAndNewlines),
                date: date
            )
        )

        await cacheService.upsertLedgerEntry(entry)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: entry.id, appState: appState, logger: logger, context: "SpendingService.withdraw")
        return entry
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

        let isOwnerForIdentity = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let identity = ScopedRecordIdentity(
            databaseScope: DatabaseScopeResolver.scope(isOwner: isOwnerForIdentity),
            zoneID: entry.id.zoneID,
            recordID: entry.id,
            familyRecordName: entry.family.recordID.recordName
        )
        await cacheService.invalidate(identity: identity, type: .ledgerEntry, expectedActiveZone: appState.familyZoneID)
        ActiveFamilyScopeGuard.enqueueDeleteWithCorrectedOwner(syncCoordinator, id: entry.id, appState: appState, logger: logger, context: "SpendingService.delete")
    }
}
