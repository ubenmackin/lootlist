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
    private let cloudKit: CloudKitService
    var cacheService: CacheService?

    init(cloudKit: CloudKitService, cacheService: CacheService? = nil) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
    }

    func isAvailable() -> Bool {
        true
    }

    func fetchTransactions(for profile: Profile,
                           in dateRange: DateInterval) async throws -> [LedgerEntry]
    {
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
        let zoneID = cloudKit.resolvedZoneID
        let db = cloudKit.activeFamilyDatabase
        let saved = try await cloudKit.save(entry, in: zoneID, using: db)
        cacheService?.upsertLedgerEntry(saved)
        return saved
    }

    func delete(_ entry: LedgerEntry) async throws {
        try await cloudKit.delete(entry.id)
    }
}
