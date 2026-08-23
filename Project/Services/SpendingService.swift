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
    var cacheService: CacheService?
    var syncCoordinator: CKSyncEngineCoordinator?

    var toastManager: ToastManager?

    var appState: AppState?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "ManualSpending")

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

    // MARK: - Fetch

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
            if !filtered.isEmpty || !cached.isEmpty {
                if !filtered.isEmpty {
                    logger.debug("fetchTransactions: returning cached \(filtered.count) rows without freshness stamp for new hero")
                }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "profile == %@", profileRef as CVarArg)
        let isOwner = targetZoneID.ownerName == CKCurrentUserDefaultName || (appState?.isZoneOwner == true && appState?.familyZoneID == targetZoneID)
        let db = cloudKit.database(isOwner: isOwner)
        do {
            let all = try await cloudKit.query(
                LedgerEntry.self,
                predicate: predicate,
                in: targetZoneID,
                sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)],
                using: db
            )
            cacheService?.upsertLedgerEntries(all)
            return all.filter { dateRange.contains($0.date) }
        } catch {
            logger.warning("fetchTransactions CloudKit query failed, falling back to cache: \(error, privacy: .private)")
            if let cache = cacheService {
                let profileName = profile.id.recordName
                let familyName = profile.family.recordID.recordName
                let cached = cache.fetchLedgerEntries(profileRecordName: profileName, family: familyName)
                return cached.filter { dateRange.contains($0.date) }.map { cacheRow in
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
            throw error
        }
    }

    // MARK: - Helpers

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
        guard let appState else { throw ScopeViolation.noActiveFamily }
        do {
            try ActiveFamilyScopeGuard.requireActiveFamilyScope(family: family, cloudKit: cloudKit, appState: appState)
        } catch {
            logger.warning("Strict scope check failed, falling back to family-only check: \(error, privacy: .private)")
            try ActiveFamilyScopeGuard.requireActiveFamily(familyRecordName: family.id.recordName, appState: appState)
        }
    }

    private func makeLedgerID(source: String, profile: Profile, family: Family, amount: Double, description: String, date: Date) -> CKRecord.ID {
        var base = deterministicRecordName(source: source, profile: profile, family: family, amount: amount, description: description, date: date)
        if let cache = cacheService, cache.fetchLedgerEntry(recordName: base, family: family.id.recordName) != nil {
            base += "-\(UUID().uuidString.prefix(8))"
        }
        return CKRecord.ID(recordName: base, zoneID: family.id.zoneID)
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
        guard let appState else {
            throw ScopeViolation.noActiveFamily
        }
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
            source: "manual",
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: makeLedgerID(source: "manual", profile: profile, family: family, amount: amount, description: trimmedDesc, date: date)
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
            id: makeLedgerID(source: "deposit", profile: profile, family: family, amount: amount, description: trimmedDesc, date: date)
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
            id: makeLedgerID(source: "withdrawal", profile: profile, family: family, amount: amount, description: trimmedDesc, date: date)
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
        cacheService?.invalidate(recordName: name, family: entry.family.recordID.recordName, type: .ledgerEntry)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueDelete(recordID: entry.id, isOwner: isOwner)
    }
}
