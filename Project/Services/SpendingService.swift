//
//  SpendingService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
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
    var ledgerService: LedgerService?

    var resolvedLedgerService: LedgerService {
        if let ledgerService {
            return ledgerService
        }
        return LedgerService(
            cloudKit: cloudKit,
            cacheService: cacheService,
            appState: appState,
            syncCoordinator: syncCoordinator
        )
    }

    var toastManager: ToastManager?

    let appState: AppState

    private static let staticLogger = Logger(category: "ManualSpending")

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
        self.init(
            cloudKit: cloudKit,
            cacheService: ServiceInitHelper.resolveCacheService(provided: cacheService, logger: Self.staticLogger, serviceName: "SpendingService"),
            appState: appState ?? AppState(),
            syncCoordinator: ServiceInitHelper.resolveSyncCoordinator(provided: syncCoordinator, logger: Self.staticLogger, serviceName: "SpendingService")
        )
    }

    func isAvailable() -> Bool {
        true
    }

    // MARK: - Fetch (delegates to LedgerService)

    func fetchTransactions(for profile: Profile,
                           in dateRange: DateInterval) async throws -> [LedgerEntry]
    {
        try await resolvedLedgerService.fetchTransactions(for: profile, in: dateRange)
    }

    // MARK: - Mutations (delegates to LedgerService; UI coordination stays here)

    func logManual(profile: Profile,
                   family: Family,
                   familyRecordName: String,
                   description: String,
                   amount: Int64,
                   location: String? = nil,
                   date: Date = Date()) async throws -> LedgerEntry
    {
        try await resolvedLedgerService.logManual(
            profile: profile,
            family: family,
            familyRecordName: familyRecordName,
            description: description,
            amount: amount,
            location: location,
            date: date
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
        try await resolvedLedgerService.depositEntries(
            profile: profile,
            family: family,
            familyRecordName: familyRecordName,
            description: description,
            amount: amount,
            location: location,
            date: date
        )
    }

    func withdraw(profile: Profile,
                  family: Family,
                  familyRecordName: String,
                  description: String,
                  amount: Int64,
                  location: String? = nil,
                  date: Date = Date()) async throws -> LedgerEntry
    {
        try await resolvedLedgerService.withdraw(
            profile: profile,
            family: family,
            familyRecordName: familyRecordName,
            description: description,
            amount: amount,
            location: location,
            date: date
        )
    }

    func delete(_ entry: LedgerEntry) async throws {
        try await resolvedLedgerService.delete(entry)
    }
}
