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
        case let .underlying(msg): msg
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
                   date: Date) async throws -> LedgerEntry

    func delete(_ entry: LedgerEntry) async throws
}

extension SpendingService {
    func logManual(profile _: Profile,
                   family _: Family,
                   familyRecordName _: String,
                   description _: String,
                   amount _: Double,
                   date _: Date) async throws -> LedgerEntry
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

    var toastManager: ToastManager?

    var appState: AppState?

    init(cloudKit: any CloudKitServiceProtocol, cacheService: CacheService? = nil, appState: AppState? = nil) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.appState = appState
    }

    func isAvailable() -> Bool {
        true
    }

    func fetchTransactions(for profile: Profile,
                           in dateRange: DateInterval) async throws -> [LedgerEntry]
    {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchLedgerEntries(profileRecordName: profileName, family: familyName)
            let filtered = cached.filter { dateRange.contains($0.date) }
            if !filtered.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .ledgerEntry) {
                let zoneID = cloudKit.resolvedZoneID
                return filtered.map { cacheRow in
                    LedgerEntry(
                        profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: cacheRow.profileRecordName, zoneID: zoneID), action: .none),
                        amount: cacheRow.amount,
                        description: cacheRow.entryDescription,
                        date: cacheRow.date,
                        source: cacheRow.source,
                        family: CKRecord.Reference(recordID: CKRecord.ID(recordName: cacheRow.familyRecordName, zoneID: zoneID), action: .none),
                        id: CKRecord.ID(recordName: cacheRow.recordName, zoneID: zoneID)
                    )
                }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "profile == %@", profileRef as CVarArg)
        let all = try await cloudKit.query(
            LedgerEntry.self,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)]
        )
        cacheService?.upsertLedgerEntries(all)
        return all.filter { dateRange.contains($0.date) }
    }

    func logManual(profile: Profile,
                   family: Family,
                   familyRecordName: String,
                   description: String,
                   amount: Double,
                   date: Date = Date()) async throws -> LedgerEntry
    {
        guard let acting = appState?.currentProfile, acting.id == profile.id else {
            throw FamilyServiceError.unauthorized
        }

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
            date: date,
            source: "manual",
            family: CKRecord.Reference(recordID: family.id, action: .none)
        )
        let name = entry.id.recordName
        // Scope the snapshot fetch to the active family so a profile that
        // briefly existed in two families does not match rows from the other.
        let snapshot = cacheService?.fetchLedgerEntries(profileRecordName: profile.id.recordName, family: familyRecordName)
            .first(where: { $0.recordName == name })
        let preMutationChangeTag = snapshot?.changeTag

        let snapshotEntry: LedgerEntry? = snapshot?.toLedgerEntry(zoneID: cloudKit.resolvedZoneID)
        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertLedgerEntry(entry)
        do {
            let zoneID = cloudKit.resolvedZoneID
            let saved = try await cloudKit.save(entry, in: zoneID)
            cacheService?.upsertLedgerEntry(saved)
            await registry?.deregister(name)
            return saved
        } catch {
            await OptimisticFailureHandler.handleSaveFailure(
                recordID: entry.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotEntry,
                cloudKit: cloudKit,
                toastManager: toastManager,
                fetchCurrentTag: {
                    self.cacheService?.fetchLedgerEntries(profileRecordName: profile.id.recordName, family: familyRecordName).first(where: { $0.recordName == name })?.changeTag
                },
                upsert: { restored in self.cacheService?.upsertLedgerEntry(restored) },
                invalidate: { _ in self.cacheService?.invalidateLedgerEntry(recordName: name) },
                error: error
            )
            await registry?.deregister(name)
            throw SpendingServiceError.persistenceFailed
        }
    }

    func delete(_ entry: LedgerEntry) async throws {
        guard let acting = appState?.currentProfile,
              entry.profile.recordID == acting.id || acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }

        let name = entry.id.recordName
        let snapshot = cacheService?.fetchLedgerEntries(profileRecordName: entry.profile.recordID.recordName)
            .first(where: { $0.recordName == name })
        let preMutationChangeTag = snapshot?.changeTag
        let snapshotEntry: LedgerEntry? = snapshot?.toLedgerEntry(zoneID: cloudKit.resolvedZoneID)

        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.invalidateLedgerEntry(recordName: name)
        do {
            try await cloudKit.delete(entry.id, in: nil, using: nil)
            await registry?.deregister(name)
        } catch {
            await OptimisticFailureHandler.handleSaveFailure(
                recordID: entry.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotEntry,
                cloudKit: cloudKit,
                toastManager: toastManager,
                fetchCurrentTag: { self.cacheService?.fetchLedgerEntries(profileRecordName: entry.profile.recordID.recordName).first(where: { $0.recordName == name })?.changeTag },
                upsert: { restored in self.cacheService?.upsertLedgerEntry(restored) },
                invalidate: { _ in self.cacheService?.invalidateLedgerEntry(recordName: name) },
                error: error
            )
            await registry?.deregister(name)
            throw SpendingServiceError.persistenceFailed
        }
    }
}
