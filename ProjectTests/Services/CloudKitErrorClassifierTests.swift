//
//  CloudKitErrorClassifierTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/10/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

/// WHY single gate: CacheFirst falls back to stale cache only on transient.
/// Classification lives solely in CKSyncConflictResolver; this suite pins its verdicts.
struct ResolverTransientClassificationTests {
    // MARK: - Transient CKError codes

    @Test(arguments: [
        CKError.Code.networkUnavailable,
        .networkFailure,
        .serviceUnavailable,
        .requestRateLimited,
        .zoneBusy,
        .operationCancelled,
        .notAuthenticated
    ])
    func `transient codes return true`(code: CKError.Code) {
        #expect(CKSyncConflictResolver.isTransient(CKError(code)))
    }

    // MARK: - serverRejectedRequest only where retryable

    @Test
    func `plain serverRejectedRequest returns false`() {
        #expect(!CKSyncConflictResolver.isTransient(CKError(.serverRejectedRequest)))
    }

    @Test
    func `serverRejectedRequest with timeout bridge returns false`() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let error = CKError(.serverRejectedRequest, userInfo: [NSUnderlyingErrorKey: timeout])
        #expect(!CKSyncConflictResolver.isTransient(error))
    }

    // MARK: - Timeout variants

    @Test
    func `direct NSURLError timeout returns false`() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(!CKSyncConflictResolver.isTransient(timeout))
    }

    @Test
    func `retryable CKError with timeout bridge returns true`() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let error = CKError(.networkUnavailable, userInfo: [NSUnderlyingErrorKey: timeout])
        #expect(CKSyncConflictResolver.isTransient(error))
    }

    @Test
    func `persistent code with timeout bridge still returns false`() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let error = CKError(.unknownItem, userInfo: [NSUnderlyingErrorKey: timeout])
        #expect(!CKSyncConflictResolver.isTransient(error))
    }

    // MARK: - Persistent CKError codes

    @Test(arguments: [
        CKError.Code.permissionFailure,
        .quotaExceeded,
        .badContainer,
        .badDatabase,
        .changeTokenExpired,
        .unknownItem,
        .referenceViolation,
        .managedAccountRestricted,
        .assetFileNotFound,
        .invalidArguments
    ])
    func `persistent codes return false`(code: CKError.Code) {
        #expect(!CKSyncConflictResolver.isTransient(CKError(code)))
    }

    // MARK: - Partial failures defer safely

    @Test
    func `partialFailure with transient nested errors returns true`() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let recordID = CKRecord.ID(recordName: "r1", zoneID: zoneID)
        let nested = CKError(.networkUnavailable)
        let error = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [recordID: nested]])
        #expect(CKSyncConflictResolver.isTransient(error))
    }

    @Test
    func `partialFailure with persistent nested errors returns false`() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let recordID = CKRecord.ID(recordName: "r1", zoneID: zoneID)
        let nested = CKError(.unknownItem)
        let error = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [recordID: nested]])
        #expect(!CKSyncConflictResolver.isTransient(error))
    }

    @Test
    func `partialFailure with mixed nested errors returns false`() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let first = CKRecord.ID(recordName: "r1", zoneID: zoneID)
        let second = CKRecord.ID(recordName: "r2", zoneID: zoneID)
        let partials: [CKRecord.ID: CKError] = [
            first: CKError(.networkFailure),
            second: CKError(.permissionFailure)
        ]
        let error = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: partials])
        #expect(!CKSyncConflictResolver.isTransient(error))
    }

    @Test
    func `NSError wrapping transient CKError defers safely`() {
        // WHY conservative: only direct CKError or timeout bridge counts as transient.
        let wrapped = NSError(
            domain: NSPOSIXErrorDomain,
            code: 0,
            userInfo: [NSUnderlyingErrorKey: CKError(.networkUnavailable)]
        )
        #expect(!CKSyncConflictResolver.isTransient(wrapped))
    }

    // MARK: - Cancellation and foundation errors are not transient

    @Test
    func `operationCancelled returns true`() {
        #expect(CKSyncConflictResolver.isTransient(CKError(.operationCancelled)))
    }

    @Test
    func `swift cancellation returns false`() {
        #expect(!CKSyncConflictResolver.isTransient(CancellationError()))
    }

    @Test
    func `NSURLErrorCancelled returns false`() {
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        #expect(!CKSyncConflictResolver.isTransient(cancelled))
    }

    @Test
    func `non-timeout NSURLError returns false`() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(!CKSyncConflictResolver.isTransient(offline))
    }

    @Test
    func `generic NSError returns false`() {
        let generic = NSError(domain: "TestDomain", code: 42)
        #expect(!CKSyncConflictResolver.isTransient(generic))
    }

    // MARK: - Retry set vs hard failures

    @Test
    func `notAuthenticated returns true`() {
        #expect(CKSyncConflictResolver.isTransient(CKError(.notAuthenticated)))
    }

    @Test(arguments: [
        CKError.Code.managedAccountRestricted,
        .userDeletedZone
    ])
    func `other hard auth codes return false`(code: CKError.Code) {
        #expect(!CKSyncConflictResolver.isTransient(CKError(code)))
    }

    @Test
    func `notAuthenticated stays retry even with timeout bridge`() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let error = CKError(.notAuthenticated, userInfo: [NSUnderlyingErrorKey: timeout])
        #expect(CKSyncConflictResolver.isTransient(error))
    }

    // MARK: - CloudKitServiceError mapping

    @Test
    func `service transient cases return true`() {
        #expect(CKSyncConflictResolver.isTransient(CloudKitServiceError.networkUnavailable))
        #expect(CKSyncConflictResolver.isTransient(CloudKitServiceError.retryable(attempt: 1, code: nil)))
        #expect(CKSyncConflictResolver.isTransient(CloudKitServiceError.exhaustedBudget(attempt: 3)))
    }

    @Test
    func `service persistent cases return false`() {
        #expect(!CKSyncConflictResolver.isTransient(CloudKitServiceError.accountUnavailable))
        #expect(!CKSyncConflictResolver.isTransient(CloudKitServiceError.notFound("x")))
        #expect(!CKSyncConflictResolver.isTransient(CloudKitServiceError.serverRecordChanged))
        #expect(!CKSyncConflictResolver.isTransient(CloudKitServiceError.changeTokenExpired))
        #expect(!CKSyncConflictResolver.isTransient(CloudKitServiceError.zoneNotFound))
        #expect(!CKSyncConflictResolver.isTransient(CloudKitServiceError.invalidArguments("x")))
        #expect(!CKSyncConflictResolver.isTransient(CloudKitServiceError.underlying("x")))
        #expect(!CKSyncConflictResolver.isTransient(CloudKitServiceError.shareFailed("x")))
        #expect(!CKSyncConflictResolver.isTransient(CloudKitServiceError.zoneSetupFailed("x")))
        #expect(!CKSyncConflictResolver.isTransient(CloudKitServiceError.paginationExhausted(pageBudget: 5)))
        #expect(!CKSyncConflictResolver.isTransient(CloudKitServiceError.shareAcceptFailed(code: .unknownItem, message: "x")))
    }
}
