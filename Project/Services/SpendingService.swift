//
//  SpendingService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

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
protocol SpendingService: Sendable {
    func fetchTransactions(for profile: Profile,
                           in dateRange: DateInterval) async throws -> [LedgerEntry]

    func isAvailable() -> Bool

    func logManual(profile: Profile,
                   family: Family,
                   familyRecordName: String,
                   description: String,
                   amount: Double,
                   location: String?,
                   date: Date) async throws -> LedgerEntry

    func deposit(profile: Profile,
                 family: Family,
                 familyRecordName: String,
                 description: String,
                 amount: Double,
                 location: String?,
                 date: Date) async throws -> LedgerEntry

    func withdraw(profile: Profile,
                  family: Family,
                  familyRecordName: String,
                  description: String,
                  amount: Double,
                  location: String?,
                  date: Date) async throws -> LedgerEntry

    func delete(_ entry: LedgerEntry) async throws
}

extension SpendingService {
    func logManual(profile _: Profile,
                   family _: Family,
                   familyRecordName _: String,
                   description _: String,
                   amount _: Double,
                   location _: String? = nil,
                   date _: Date = Date()) async throws -> LedgerEntry
    {
        throw SpendingServiceError.unsupported
    }

    func deposit(profile _: Profile,
                 family _: Family,
                 familyRecordName _: String,
                 description _: String,
                 amount _: Double,
                 location _: String? = nil,
                 date _: Date = Date()) async throws -> LedgerEntry
    {
        throw SpendingServiceError.unsupported
    }

    func withdraw(profile _: Profile,
                  family _: Family,
                  familyRecordName _: String,
                  description _: String,
                  amount _: Double,
                  location _: String? = nil,
                  date _: Date = Date()) async throws -> LedgerEntry
    {
        throw SpendingServiceError.unsupported
    }

    func delete(_: LedgerEntry) async throws {
        throw SpendingServiceError.unsupported
    }
}

@MainActor
final class ManualSpendingService: SpendingService {
    private let cloudKit: any CloudKitServiceProtocol
    var cacheService: CacheService?
    var syncCoordinator: CKSyncEngineCoordinator?

    var toastManager: ToastManager?

    var appState: AppState?

    init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService? = nil,
        appState: AppState? = nil,
        syncCoordinator: CKSyncEngineCoordinator? = nil
    ) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
    }

    func isAvailable() -> Bool {
        true
    }

    func fetchTransactions(for profile: Profile,
                           in dateRange: DateInterval) async throws -> [LedgerEntry]
    {
        let targetZoneID = profile.family.recordID.zoneID
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchLedgerEntries(profileRecordName: profileName, family: familyName)
            let filtered = cached.filter { dateRange.contains($0.date) }
            if cache.isCacheFresh(familyRecordName: familyName, type: .ledgerEntry) {
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
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "profile == %@", profileRef as CVarArg)
        let isOwner = targetZoneID.ownerName == CKCurrentUserDefaultName || (appState?.isZoneOwner == true && appState?.familyZoneID == targetZoneID)
        let db = cloudKit.database(isOwner: isOwner)
        let all = try await cloudKit.query(
            LedgerEntry.self,
            predicate: predicate,
            in: targetZoneID,
            sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)],
            using: db
        )
        cacheService?.upsertLedgerEntries(all)
        return all.filter { dateRange.contains($0.date) }
    }

    func logManual(profile: Profile,
                   family: Family,
                   familyRecordName: String,
                   description: String,
                   amount: Double,
                   location: String? = nil,
                   date: Date = Date()) async throws -> LedgerEntry
    {
        guard let appState else {
            throw ScopeViolation.noActiveFamily
        }
        guard familyRecordName == family.id.recordName else {
            throw ScopeViolation.familyMismatch(active: family.id.recordName, supplied: familyRecordName)
        }
        guard let acting = appState.currentProfile, acting.id == profile.id || acting.role.isParent else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(family: family, cloudKit: cloudKit, appState: appState)

        guard amount.isFinite else {
            throw SpendingServiceError.invalidAmount
        }
        guard amount > 0 else {
            throw SpendingServiceError.invalidAmount
        }

        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            amount: -abs(amount),
            description: description,
            location: location,
            date: date,
            source: "manual",
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: UUID().uuidString, zoneID: family.id.zoneID)
        )

        cacheService?.upsertLedgerEntry(entry)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: entry.id, isOwner: isOwner)
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
        guard let appState else {
            throw ScopeViolation.noActiveFamily
        }
        guard familyRecordName == family.id.recordName else {
            throw ScopeViolation.familyMismatch(active: family.id.recordName, supplied: familyRecordName)
        }
        guard let acting = appState.currentProfile, acting.role.isParent else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(family: family, cloudKit: cloudKit, appState: appState)

        guard amount.isFinite, amount > 0 else {
            throw SpendingServiceError.invalidAmount
        }

        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            amount: abs(amount),
            description: description,
            location: location,
            date: date,
            source: "deposit",
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: UUID().uuidString, zoneID: family.id.zoneID)
        )

        cacheService?.upsertLedgerEntry(entry)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: entry.id, isOwner: isOwner)
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
        guard let appState else {
            throw ScopeViolation.noActiveFamily
        }
        guard familyRecordName == family.id.recordName else {
            throw ScopeViolation.familyMismatch(active: family.id.recordName, supplied: familyRecordName)
        }
        guard let acting = appState.currentProfile, acting.role.isParent else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(family: family, cloudKit: cloudKit, appState: appState)

        guard amount.isFinite, amount > 0 else {
            throw SpendingServiceError.invalidAmount
        }

        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            amount: -abs(amount),
            description: description,
            location: location,
            date: date,
            source: "withdrawal",
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: UUID().uuidString, zoneID: family.id.zoneID)
        )

        cacheService?.upsertLedgerEntry(entry)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: entry.id, isOwner: isOwner)
        return entry
    }

    func delete(_ entry: LedgerEntry) async throws {
        guard entry.source != "quest" else {
            throw SpendingServiceError.unsupported
        }

        guard let appState else {
            throw ScopeViolation.noActiveFamily
        }

        guard let acting = appState.currentProfile,
              entry.profile.recordID == acting.id || acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }

        try ActiveFamilyScopeGuard.requireActiveFamily(familyRef: entry.family, appState: appState)

        let name = entry.id.recordName
        cacheService?.invalidateLedgerEntry(recordName: name, family: entry.family.recordID.recordName)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueDelete(recordID: entry.id, isOwner: isOwner)
    }
}
