import Foundation
import CloudKit

enum SpendingServiceError: Error, Equatable, Sendable {

    case unsupported

    case invalidAmount

    case underlying(String)
}

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

    func logManual(profile: Profile,
                   family: Family,
                   description: String,
                   amount: Double,
                   date: Date) async throws -> LedgerEntry {
        throw SpendingServiceError.unsupported
    }

    func delete(_ entry: LedgerEntry) async throws {
        throw SpendingServiceError.unsupported
    }
}

final class ManualSpendingService: SpendingService, @unchecked Sendable {

    private let cloudKit: CloudKitService

    init(cloudKit: CloudKitService) {
        self.cloudKit = cloudKit
    }

    func isAvailable() -> Bool { true }

    func fetchTransactions(for profile: Profile,
                            in dateRange: DateInterval) async throws -> [LedgerEntry] {

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(
            format: "profile == %@ AND date >= %@ AND date <= %@",
            profileRef as CVarArg,
            dateRange.start as CVarArg,
            dateRange.end as CVarArg
        )
        return try await cloudKit.query(
            LedgerEntry.self,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)]
        )
    }

    func logManual(profile: Profile,
                   family: Family,
                   description: String,
                   amount: Double,
                   date: Date = Date()) async throws -> LedgerEntry {

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
        return try await cloudKit.save(entry)
    }

    func delete(_ entry: LedgerEntry) async throws {
        try await cloudKit.delete(entry.id)
    }
}
