//
//  CKSyncConflictResolverTests.swift
//  LootList
//
//  Created by Ben Mackin on 10/18/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
@Suite(.serialized)
struct CKSyncConflictResolverTests {
    let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")

    // MARK: - Save Failure Disposition Matrix

    @Test
    func `disposition classifies transient codes for retry`() {
        let transientCodes: [CKError.Code] = [
            .networkUnavailable,
            .networkFailure,
            .serviceUnavailable,
            .requestRateLimited,
            .operationCancelled,
            .zoneBusy,
            .notAuthenticated
        ]
        for code in transientCodes {
            #expect(CKSyncConflictResolver.disposition(for: CKError(code)) == .retry, "expected retry for \(code)")
        }
    }

    @Test
    func `disposition keeps handled branches and unmapped codes on discard`() {
        let discardCodes: [CKError.Code] = [
            .serverRecordChanged,
            .unknownItem,
            .zoneNotFound,
            .quotaExceeded,
            .serverRejectedRequest,
            .permissionFailure,
            .changeTokenExpired,
            .limitExceeded
        ]
        for code in discardCodes {
            #expect(CKSyncConflictResolver.disposition(for: CKError(code)) == .discard, "expected discard for \(code)")
        }
    }

    @Test
    func `disposition retries partialFailure only when every sub-error is transient`() {
        let partial = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [
                CKRecord.ID(recordName: "sub-1"): CKError(.networkUnavailable),
                CKRecord.ID(recordName: "sub-2"): CKError(.zoneBusy)
            ] as [CKRecord.ID: Error]
        ])
        #expect(CKSyncConflictResolver.disposition(for: partial) == .retry)
    }

    @Test
    func `disposition discards partialFailure with any permanent sub-error`() {
        let permanentSubErrors: [CKError] = [
            CKError(.quotaExceeded),
            CKError(.permissionFailure),
            CKError(.serverRecordChanged),
            CKError(.partialFailure, userInfo: [
                CKPartialErrorsByItemIDKey: [
                    CKRecord.ID(recordName: "nested"): CKError(.limitExceeded)
                ] as [CKRecord.ID: Error]
            ])
        ]
        for subError in permanentSubErrors {
            let partial = CKError(.partialFailure, userInfo: [
                CKPartialErrorsByItemIDKey: [
                    CKRecord.ID(recordName: "sub-transient"): CKError(.networkUnavailable),
                    CKRecord.ID(recordName: "sub-permanent"): subError
                ] as [CKRecord.ID: Error]
            ])
            #expect(CKSyncConflictResolver.disposition(for: partial) == .discard, "expected discard for sub-error \(subError.code)")
        }
    }

    @Test
    func `disposition discards partialFailure with unclassifiable or missing sub-errors`() {
        let nonCKErrorSub = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [
                CKRecord.ID(recordName: "sub-1"): NSError(domain: CKErrorDomain, code: -1)
            ] as [CKRecord.ID: Error]
        ])
        #expect(CKSyncConflictResolver.disposition(for: nonCKErrorSub) == .discard)

        // A bare partialFailure carries no sub-error map — no transience evidence, fail closed.
        #expect(CKSyncConflictResolver.disposition(for: CKError(.partialFailure)) == .discard)

        let emptySubErrors = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [:] as [CKRecord.ID: Error]
        ])
        #expect(CKSyncConflictResolver.disposition(for: emptySubErrors) == .discard)
    }

    // MARK: - Resolver Behavior

    private func transferRecord(recordName: String, amount: Int64) -> CKRecord {
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let profileRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none)
        let entry = LedgerEntry(
            profile: profileRef,
            amount: amount,
            description: "Bucket move",
            date: Date(),
            source: LedgerSource.transfer.rawValue,
            bucketKind: BucketKind.shortTermSave.rawValue,
            fromBucket: BucketKind.spend.rawValue,
            toBucket: BucketKind.shortTermSave.rawValue,
            family: familyRef,
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
        return entry.toRecord()
    }

    @Test
    func `resolver returns original record for transient save error and nil for permanent`() async throws {
        let cache = try CacheService(inMemory: true)
        let resolver = CKSyncConflictResolver(cacheService: cache)

        let record = transferRecord(recordName: "ledger_transient_retry", amount: 125)

        let resolved = await resolver.resolveFailedSave(record: record, error: CKError(.networkUnavailable), databaseScope: .private)
        #expect(resolved === record)
        #expect(resolved?["amount"] as? Int64 == 125)

        #expect(await resolver.resolveFailedSave(record: record, error: CKError(.quotaExceeded), databaseScope: .private) == nil)
        #expect(await resolver.resolveFailedSave(record: record, error: CKError(.serverRejectedRequest), databaseScope: .private) == nil)
    }

    // MARK: - Delegate Failed-Save Routing

    private struct FailedSaveHarness {
        let cache: CacheService
        let toastManager: ToastManager
        let delegate: CKSyncEngineDelegateHandler
        let coordinator: CKSyncEngineCoordinator
        let engine: CKSyncEngine
    }

    private func makeFailedSaveHarness(
        suiteName: String
    ) throws -> FailedSaveHarness {
        let ck = MockCloudKitService()
        let cache = try CacheService(inMemory: true)
        let resolver = CKSyncConflictResolver(cacheService: cache)
        let toastManager = ToastManager()
        let delegate = CKSyncEngineDelegateHandler(
            conflictResolver: resolver,
            cacheService: cache,
            toastManager: toastManager
        )
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let coordinator = CKSyncEngineCoordinator(
            cloudKitService: ck,
            delegateHandler: delegate,
            defaults: defaults
        )
        let engine = CKSyncEngine(
            CKSyncEngine.Configuration(
                database: ck.container.privateCloudDatabase,
                stateSerialization: nil,
                delegate: delegate
            )
        )
        return FailedSaveHarness(cache: cache, toastManager: toastManager, delegate: delegate, coordinator: coordinator, engine: engine)
    }

    @Test
    func `delegate retries transient failed save without toast or freshness loss`() async throws {
        let harness = try makeFailedSaveHarness(suiteName: "cksync-transient-retry-\(UUID().uuidString)")
        let record = transferRecord(recordName: "ledger_retry_transient", amount: 5)
        harness.cache.markCacheFreshForTests(familyRecordName: "fam1", type: .ledgerEntry)

        await harness.delegate.simulateFailedRecordSaves(
            [(record: record, error: CKError(.networkUnavailable))],
            syncEngine: harness.engine
        )

        #expect(harness.engine.state.pendingRecordZoneChanges.contains(.saveRecord(record.recordID)))
        #if DEBUG
            #expect(harness.delegate.retryScheduleRequests.count == 1)
            #expect(harness.delegate.retryScheduleRequests.first?.recordID == record.recordID)
            #expect(harness.delegate.retryScheduleRequests.first?.isOwner == true)
        #endif
        #expect(harness.toastManager.toasts.isEmpty)
        #expect(harness.cache.isCacheAuthoritative(familyRecordName: "fam1", type: .ledgerEntry, scope: .private))
    }

    @Test
    func `delegate discards quota failed save with toast and freshness loss`() async throws {
        let harness = try makeFailedSaveHarness(suiteName: "cksync-quota-discard-\(UUID().uuidString)")
        let record = transferRecord(recordName: "ledger_quota_discard", amount: 7)
        harness.cache.markCacheFreshForTests(familyRecordName: "fam1", type: .ledgerEntry)

        await harness.delegate.simulateFailedRecordSaves(
            [(record: record, error: CKError(.quotaExceeded))],
            syncEngine: harness.engine
        )

        #expect(!harness.engine.state.pendingRecordZoneChanges.contains(.saveRecord(record.recordID)))
        #if DEBUG
            #expect(harness.delegate.retryScheduleRequests.isEmpty)
        #endif
        #expect(!harness.cache.isCacheAuthoritative(familyRecordName: "fam1", type: .ledgerEntry, scope: .private))
        #expect(harness.toastManager.toasts.count == 1)
        #expect(harness.toastManager.toasts.first?.message == harness.delegate.discardedSaveMessage(for: record))
        #expect(harness.toastManager.toasts.first?.type == .warning)
    }

    // MARK: - Retry Budget Termination

    @Test
    func `scheduleRetry schedules within the backoff budget then refuses and resets on success`() throws {
        let harness = try makeFailedSaveHarness(suiteName: "cksync-retry-budget-\(UUID().uuidString)")
        let recordID = CKRecord.ID(recordName: "ledger_retry_budget", zoneID: zoneID)
        let otherID = CKRecord.ID(recordName: "ledger_retry_budget_other", zoneID: zoneID)

        for _ in 0 ..< AppConstants.CloudKit.backoffScheduleNanos.count {
            #expect(harness.coordinator.scheduleRetry(for: recordID, isOwner: true))
        }
        // Budget spent: the next failure must not re-enter the backoff.
        #expect(!harness.coordinator.scheduleRetry(for: recordID, isOwner: true))
        // The budget is per record: a different record still schedules.
        #expect(harness.coordinator.scheduleRetry(for: otherID, isOwner: true))
        // A successful send clears the spent budget for a fresh window.
        harness.coordinator.clearRetryState(for: recordID)
        #expect(harness.coordinator.scheduleRetry(for: recordID, isOwner: true))
    }

    @Test
    func `delegate falls through to discard with toast once the retry budget is exhausted`() async throws {
        let harness = try makeFailedSaveHarness(suiteName: "cksync-retry-exhaust-\(UUID().uuidString)")
        let record = transferRecord(recordName: "ledger_retry_exhaust", amount: 9)
        harness.cache.markCacheFreshForTests(familyRecordName: "fam1", type: .ledgerEntry)

        // Spend the budget synchronously so no engine send can interleave; the
        // next transient failure must surface as a discard, not a silent retry.
        for _ in 0 ..< AppConstants.CloudKit.backoffScheduleNanos.count {
            #expect(harness.coordinator.scheduleRetry(for: record.recordID, isOwner: true))
        }

        await harness.delegate.simulateFailedRecordSaves(
            [(record: record, error: CKError(.networkUnavailable))],
            syncEngine: harness.engine
        )

        #expect(!harness.engine.state.pendingRecordZoneChanges.contains(.saveRecord(record.recordID)))
        #if DEBUG
            #expect(harness.delegate.retryScheduleRequests.isEmpty)
        #endif
        #expect(!harness.cache.isCacheAuthoritative(familyRecordName: "fam1", type: .ledgerEntry, scope: .private))
        #expect(harness.toastManager.toasts.count == 1)
        #expect(harness.toastManager.toasts.first?.type == .warning)
        #expect(harness.toastManager.toasts.first?.message == harness.delegate.discardedSaveMessage(for: record))
    }

    @Test
    func `consecutive transient failures accumulate attempts until the budget exhausts`() async throws {
        let harness = try makeFailedSaveHarness(suiteName: "cksync-retry-consecutive-\(UUID().uuidString)")
        let record = transferRecord(recordName: "ledger_retry_consecutive", amount: 11)
        harness.cache.markCacheFreshForTests(familyRecordName: "fam1", type: .ledgerEntry)
        let budget = AppConstants.CloudKit.backoffScheduleNanos.count

        // Each consecutive failure must consume one budget slot: nothing resets the
        // attempt counter between sends, so retries stay bounded by the backoff budget.
        for attempt in 1 ... budget {
            await harness.delegate.simulateFailedRecordSaves(
                [(record: record, error: CKError(.networkUnavailable))],
                syncEngine: harness.engine
            )
            #if DEBUG
                #expect(harness.delegate.retryScheduleRequests.count == attempt)
            #endif
        }

        // The next consecutive failure falls through to discard+toast.
        await harness.delegate.simulateFailedRecordSaves(
            [(record: record, error: CKError(.networkUnavailable))],
            syncEngine: harness.engine
        )
        #if DEBUG
            #expect(harness.delegate.retryScheduleRequests.count == budget)
        #endif
        #expect(!harness.cache.isCacheAuthoritative(familyRecordName: "fam1", type: .ledgerEntry, scope: .private))
        #expect(harness.toastManager.toasts.count == 1)
        #expect(harness.toastManager.toasts.first?.type == .warning)
        #expect(harness.toastManager.toasts.first?.message == harness.delegate.discardedSaveMessage(for: record))
    }

    @Test
    func `send success clears the retry budget for a fresh window`() async throws {
        let harness = try makeFailedSaveHarness(suiteName: "cksync-retry-resend-\(UUID().uuidString)")
        let record = transferRecord(recordName: "ledger_retry_resend", amount: 13)
        harness.cache.markCacheFreshForTests(familyRecordName: "fam1", type: .ledgerEntry)
        let budget = AppConstants.CloudKit.backoffScheduleNanos.count

        // Spend all but one budget slot on consecutive failures.
        for _ in 1 ..< budget {
            await harness.delegate.simulateFailedRecordSaves(
                [(record: record, error: CKError(.networkUnavailable))],
                syncEngine: harness.engine
            )
        }
        #if DEBUG
            #expect(harness.delegate.retryScheduleRequests.count == budget - 1)
        #endif

        // A server ack of the save resets the budget — never batch preparation.
        harness.delegate.simulateSentRecordSaves([record])

        // A full budget of consecutive failures fits again after the ack.
        for _ in 1 ... budget {
            await harness.delegate.simulateFailedRecordSaves(
                [(record: record, error: CKError(.networkUnavailable))],
                syncEngine: harness.engine
            )
        }
        #if DEBUG
            #expect(harness.delegate.retryScheduleRequests.count == 2 * budget - 1)
        #endif

        // The following failure exhausts the fresh window and discards.
        await harness.delegate.simulateFailedRecordSaves(
            [(record: record, error: CKError(.networkUnavailable))],
            syncEngine: harness.engine
        )
        #if DEBUG
            #expect(harness.delegate.retryScheduleRequests.count == 2 * budget - 1)
        #endif
        #expect(harness.toastManager.toasts.count == 1)
        #expect(harness.toastManager.toasts.first?.type == .warning)
    }
}
