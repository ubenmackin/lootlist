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
