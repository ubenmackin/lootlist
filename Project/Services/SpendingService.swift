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
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: "This action isn't supported on this device."
        case .invalidAmount: "Enter a valid positive amount."
        case .persistenceFailed: "Could not save your spending. Please try again."
        case .underlying: "Something went wrong. Please try again."
        }
    }
}

@MainActor
@Observable
class SpendingService {
    private let cloudKit: any CloudKitServiceProtocol
    let cacheService: CacheService
    let syncCoordinator: CKSyncEngineCoordinator

    var toastManager: ToastManager?

    let appState: AppState

    private static let staticLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "ManualSpending")
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "ManualSpending")

    init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService,
        appState: AppState,
        syncCoordinator: CKSyncEngineCoordinator
    ) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
    }

    @_disfavoredOverload
    convenience init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService? = nil,
        appState: AppState? = nil,
        syncCoordinator: CKSyncEngineCoordinator? = nil
    ) {
        let cache: CacheService
        if let cacheService {
            cache = cacheService
        } else {
            Self.staticLogger.warning("SpendingService initialized without cacheService; using fallback in-memory cache.")
            cache = CacheService.inMemoryFallback(logger: Self.staticLogger)
        }
        let state = appState ?? AppState()
        let ck = cloudKit as? CloudKitService ?? CloudKitService()
        let delegate = CKSyncEngineDelegateHandler(
            backgroundCache: nil,
            conflictResolver: CKSyncConflictResolver(cacheService: cache, backgroundCache: nil, toastManager: nil, appState: state),
            cacheService: cache,
            appState: state
        )
        let coord = syncCoordinator ?? CKSyncEngineCoordinator(cloudKitService: ck, delegateHandler: delegate, appState: state)
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
        let cached = cacheService.fetchLedgerEntries(profileRecordName: profileName, family: familyName)
        let filtered = cached.filter { dateRange.contains($0.date) }
        let scope: CKDatabase.Scope = appState.activeDatabaseScope
        if cacheService.isCacheAuthoritative(familyRecordName: familyName, type: .ledgerEntry, scope: scope, cachedCount: cached.count) {
            return filtered.map { cacheRow in
                LedgerEntry(
                    profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: cacheRow.profileRecordName, zoneID: targetZoneID), action: .none),
                    amount: cacheRow.amount,
                    description: cacheRow.entryDescription,
                    location: cacheRow.location,
                    date: cacheRow.date,
                    source: cacheRow.source,
                    family: CKRecord.Reference(recordID: CKRecord.ID(recordName: cacheRow.familyRecordName, zoneID: targetZoneID), action: .none),
                    id: CKRecord.ID(recordName: cacheRow.recordName, zoneID: targetZoneID)
                )
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "profile == %@", profileRef as CVarArg)
        let isOwner = targetZoneID.ownerName == CKCurrentUserDefaultName || (ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) && appState.familyZoneID == targetZoneID)
        let db = cloudKit.database(isOwner: isOwner)
        do {
            let all = try await cloudKit.query(
                LedgerEntry.self,
                predicate: predicate,
                in: targetZoneID,
                sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)],
                using: db
            )
            // Scope mirrors the database the query itself ran against, which
            // this method resolves per-zone rather than from the active session.
            await syncCoordinator.delegateHandler.hydrateFromQuery(
                models: all,
                databaseScope: DatabaseScopeResolver.scope(isOwner: isOwner),
                zoneID: targetZoneID
            )
            return all.filter { dateRange.contains($0.date) }
        } catch {
            logger.warning("fetchTransactions CloudKit query failed, falling back to cache: \(error, privacy: .private)")
            let fallback = cacheService.fetchLedgerEntries(profileRecordName: profileName, family: familyName)
            return fallback.filter { dateRange.contains($0.date) }.map { cacheRow in
                LedgerEntry(
                    profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: cacheRow.profileRecordName, zoneID: targetZoneID), action: .none),
                    amount: cacheRow.amount,
                    description: cacheRow.entryDescription,
                    location: cacheRow.location,
                    date: cacheRow.date,
                    source: cacheRow.source,
                    family: CKRecord.Reference(recordID: CKRecord.ID(recordName: cacheRow.familyRecordName, zoneID: targetZoneID), action: .none),
                    id: CKRecord.ID(recordName: cacheRow.recordName, zoneID: targetZoneID)
                )
            }
        }
    }

    // MARK: - Helpers

    /// Single deterministic scheme — do not duplicate
    private func deterministicRecordName(source: String, profile: Profile, family: Family, amount: Double, description: String, date: Date) -> String {
        let ms = Int(date.timeIntervalSince1970 * 1000)
        let cents = Int((abs(amount) * 100).rounded())
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let value = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let descHash = value % 10000
        return "\(source)-\(profile.id.recordName)-\(family.id.recordName)-\(ms)-\(cents)-\(descHash)"
    }

    private func validateScopeAllowingNewHero(family: Family) throws {
        do {
            try ActiveFamilyScopeGuard.requireActiveFamilyScope(family: family, cloudKit: cloudKit, appState: appState)
        } catch {
            logger.warning("Strict scope check failed, falling back to family-only check: \(error, privacy: .private)")
            try ActiveFamilyScopeGuard.requireActiveFamily(familyRecordName: family.id.recordName, appState: appState)
        }
    }

    /// Handles manual spending replay idempotently using deterministic transaction IDs.
    private func makeLedgerID(source: String, profile: Profile, family: Family, amount: Double, description: String, location: String?, date: Date) -> CKRecord.ID {
        let base = deterministicRecordName(source: source, profile: profile, family: family, amount: amount, description: description, date: date)
        var recordName = base
        if let existing = cacheService.fetchLedgerEntry(recordName: base, family: family.id.recordName),
           existing.source != source
           || existing.entryDescription != description
           || existing.date != date
           || existing.location != location
           || Int((abs(existing.amount) * 100).rounded()) != Int((abs(amount) * 100).rounded())
        {
            recordName = "\(base)-\(UUID().uuidString)"
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

        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            amount: -abs(amount),
            description: trimmedDesc,
            location: location?.trimmingCharacters(in: .whitespacesAndNewlines),
            date: date,
            source: LedgerSource.manual.rawValue,
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

    func deposit(profile: Profile,
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
            amount: abs(amount),
            description: trimmedDesc,
            location: location?.trimmingCharacters(in: .whitespacesAndNewlines),
            date: date,
            source: "deposit",
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: makeLedgerID(
                source: "deposit",
                profile: profile,
                family: family,
                amount: amount,
                description: trimmedDesc,
                location: location?.trimmingCharacters(in: .whitespacesAndNewlines),
                date: date
            )
        )

        await cacheService.upsertLedgerEntry(entry)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: entry.id, appState: appState, logger: logger, context: "SpendingService.deposit")
        return entry
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
            source: "withdrawal",
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: makeLedgerID(
                source: "withdrawal",
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
        guard entry.source != "quest" else {
            throw SpendingServiceError.unsupported
        }

        guard let acting = appState.currentProfile,
              entry.profile.recordID == acting.id || acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }

        try ActiveFamilyScopeGuard.requireActiveFamily(familyRef: entry.family, appState: appState)

        let name = entry.id.recordName
        await cacheService.invalidate(recordName: name, family: entry.family.recordID.recordName, type: .ledgerEntry)
        ActiveFamilyScopeGuard.enqueueDeleteWithCorrectedOwner(syncCoordinator, id: entry.id, appState: appState, logger: logger, context: "SpendingService.delete")
    }
}
