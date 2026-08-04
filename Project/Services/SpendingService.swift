//
//  SpendingService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

enum SpendingServiceError: Error, Equatable, Sendable {
    case unsupported

    case invalidAmount

    case underlying(String)
}

@MainActor
protocol SpendingService: Sendable {
    func fetchTransactions(for profile: Profile,
                           in dateRange: DateInterval) async throws -> [LedgerEntry]

    func isAvailable() -> Bool

    func logManual(profile: Profile,
                   family: Family,
                   description: String,
                   amount: Double,
                   date: Date) async throws -> LedgerEntry

    func delete(_ entry: LedgerEntry) async throws
}

extension SpendingService {
    func logManual(profile _: Profile,
                   family _: Family,
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

    init(cloudKit: any CloudKitServiceProtocol, cacheService: CacheService? = nil) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
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
                   description: String,
                   amount: Double,
                   date: Date = Date()) async throws -> LedgerEntry
    {
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
        let snapshot = cacheService?.fetchLedgerEntries(profileRecordName: profile.id.recordName)
            .first(where: { $0.recordName == name })
        let preMutationChangeTag = snapshot?.changeTag

        // Register the optimistic window so a background sync skips this row.
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
            let concurrentEditDetected = ConcurrentEditDetector.detectConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { self.cacheService?.fetchLedgerEntries(profileRecordName: profile.id.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                error: error
            )

            if concurrentEditDetected {
                toastManager?.show(
                    message: "Data was modified by another device. Refresh to see the latest.",
                    type: .warning
                )
                if let fresh = try? await cloudKit.fetch(LedgerEntry.self, id: entry.id) {
                    cacheService?.upsertLedgerEntry(fresh)
                } else {
                    cacheService?.invalidateLedgerEntry(recordName: name)
                }
            } else {
                cacheService?.invalidateLedgerEntry(recordName: name)
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                toastManager?.show(message: message, type: .error)
            }
            await registry?.deregister(name)
            throw error
        }
    }

    func delete(_ entry: LedgerEntry) async throws {
        let name = entry.id.recordName
        let snapshot = cacheService?.fetchLedgerEntries(profileRecordName: entry.profile.recordID.recordName)
            .first(where: { $0.recordName == name })
        let preMutationChangeTag = snapshot?.changeTag
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        let snapshotEntry: LedgerEntry? = snapshot?.toLedgerEntry(zoneID: cloudKit.resolvedZoneID)

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.invalidateLedgerEntry(recordName: name)
        do {
            try await cloudKit.delete(entry.id, in: nil, using: nil)
            await registry?.deregister(name)
        } catch {
            let concurrentEditDetected = ConcurrentEditDetector.detectConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { self.cacheService?.fetchLedgerEntries(profileRecordName: entry.profile.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                error: error
            )

            if concurrentEditDetected {
                toastManager?.show(
                    message: "Data was modified by another device. Refresh to see the latest.",
                    type: .warning
                )
                if let fresh = try? await cloudKit.fetch(LedgerEntry.self, id: entry.id) {
                    cacheService?.upsertLedgerEntry(fresh)
                } else if let snapshotEntry {
                    cacheService?.upsertLedgerEntry(snapshotEntry)
                }
            } else {
                if let snapshotEntry {
                    cacheService?.upsertLedgerEntry(snapshotEntry)
                }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                toastManager?.show(message: message, type: .error)
            }
            await registry?.deregister(name)
            throw error
        }
    }
}
