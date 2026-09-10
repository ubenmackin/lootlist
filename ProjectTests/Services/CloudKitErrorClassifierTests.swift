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
struct CloudKitErrorClassifierTests {
    // MARK: - Transient CKError codes

    @Test(arguments: [
        CKError.Code.networkUnavailable,
        .networkFailure,
        .serviceUnavailable,
        .requestRateLimited,
        .zoneBusy
    ])
    func `transient codes return true`(code: CKError.Code) {
        #expect(CloudKitErrorClassifier.isTransient(CKError(code)))
    }

    // MARK: - serverRejectedRequest only where retryable

    @Test
    func `plain serverRejectedRequest returns false`() {
        #expect(!CloudKitErrorClassifier.isTransient(CKError(.serverRejectedRequest)))
    }

    @Test
    func `serverRejectedRequest with timeout bridge returns true`() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let error = CKError(.serverRejectedRequest, userInfo: [NSUnderlyingErrorKey: timeout])
        #expect(CloudKitErrorClassifier.isTransient(error))
    }

    // MARK: - Timeout variants

    @Test
    func `direct NSURLError timeout returns true`() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(CloudKitErrorClassifier.isTransient(timeout))
    }

    @Test
    func `CKError wrapping URL timeout returns true`() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let error = CKError(.networkUnavailable, userInfo: [NSUnderlyingErrorKey: timeout])
        #expect(CloudKitErrorClassifier.isTransient(error))
    }

    @Test
    func `persistent code with timeout bridge still returns true`() {
        // WHY timeout bridge: CloudKit wraps URL timeouts as underlying errors.
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let error = CKError(.unknownItem, userInfo: [NSUnderlyingErrorKey: timeout])
        #expect(CloudKitErrorClassifier.isTransient(error))
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
        #expect(!CloudKitErrorClassifier.isTransient(CKError(code)))
    }

    // MARK: - Partial failures defer safely

    @Test
    func `partialFailure with transient nested errors returns false`() {
        // WHY conservative: per-record failures surface instead of masking as offline.
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let recordID = CKRecord.ID(recordName: "r1", zoneID: zoneID)
        let nested = CKError(.networkUnavailable)
        let error = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [recordID: nested]])
        #expect(!CloudKitErrorClassifier.isTransient(error))
    }

    @Test
    func `partialFailure with persistent nested errors returns false`() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let recordID = CKRecord.ID(recordName: "r1", zoneID: zoneID)
        let nested = CKError(.unknownItem)
        let error = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [recordID: nested]])
        #expect(!CloudKitErrorClassifier.isTransient(error))
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
        #expect(!CloudKitErrorClassifier.isTransient(error))
    }

    @Test
    func `NSError wrapping transient CKError defers safely`() {
        // WHY conservative: only direct CKError or timeout bridge counts as transient.
        let wrapped = NSError(
            domain: NSPOSIXErrorDomain,
            code: 0,
            userInfo: [NSUnderlyingErrorKey: CKError(.networkUnavailable)]
        )
        #expect(!CloudKitErrorClassifier.isTransient(wrapped))
    }

    // MARK: - Cancellation and foundation errors are not transient

    @Test
    func `operationCancelled returns false`() {
        #expect(!CloudKitErrorClassifier.isTransient(CKError(.operationCancelled)))
    }

    @Test
    func `swift cancellation returns false`() {
        #expect(!CloudKitErrorClassifier.isTransient(CancellationError()))
    }

    @Test
    func `NSURLErrorCancelled returns false`() {
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        #expect(!CloudKitErrorClassifier.isTransient(cancelled))
    }

    @Test
    func `non-timeout NSURLError returns false`() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(!CloudKitErrorClassifier.isTransient(offline))
    }

    @Test
    func `generic NSError returns false`() {
        let generic = NSError(domain: "TestDomain", code: 42)
        #expect(!CloudKitErrorClassifier.isTransient(generic))
    }

    // MARK: - Hard auth never transient

    @Test(arguments: [
        CKError.Code.notAuthenticated,
        .managedAccountRestricted,
        .userDeletedZone
    ])
    func `hard auth codes return false`(code: CKError.Code) {
        #expect(!CloudKitErrorClassifier.isTransient(CKError(code)))
    }

    @Test
    func `hard auth wins over timeout bridge`() {
        // WHY sign-in over stale: signed-out must prompt, never masquerade as offline.
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let error = CKError(.notAuthenticated, userInfo: [NSUnderlyingErrorKey: timeout])
        #expect(!CloudKitErrorClassifier.isTransient(error))
    }

    // MARK: - CloudKitServiceError mapping

    @Test
    func `service transient cases return true`() {
        #expect(CloudKitErrorClassifier.isTransient(CloudKitServiceError.networkUnavailable))
        #expect(CloudKitErrorClassifier.isTransient(CloudKitServiceError.retryable(attempt: 1, code: nil)))
        #expect(CloudKitErrorClassifier.isTransient(CloudKitServiceError.exhaustedBudget(attempt: 3)))
    }

    @Test
    func `service persistent cases return false`() {
        #expect(!CloudKitErrorClassifier.isTransient(CloudKitServiceError.accountUnavailable))
        #expect(!CloudKitErrorClassifier.isTransient(CloudKitServiceError.notFound("x")))
        #expect(!CloudKitErrorClassifier.isTransient(CloudKitServiceError.serverRecordChanged))
        #expect(!CloudKitErrorClassifier.isTransient(CloudKitServiceError.changeTokenExpired))
        #expect(!CloudKitErrorClassifier.isTransient(CloudKitServiceError.zoneNotFound))
        #expect(!CloudKitErrorClassifier.isTransient(CloudKitServiceError.invalidArguments("x")))
        #expect(!CloudKitErrorClassifier.isTransient(CloudKitServiceError.underlying("x")))
        #expect(!CloudKitErrorClassifier.isTransient(CloudKitServiceError.shareFailed("x")))
        #expect(!CloudKitErrorClassifier.isTransient(CloudKitServiceError.zoneSetupFailed("x")))
        #expect(!CloudKitErrorClassifier.isTransient(CloudKitServiceError.paginationExhausted(pageBudget: 5)))
        #expect(!CloudKitErrorClassifier.isTransient(CloudKitServiceError.shareAcceptFailed(code: .unknownItem, message: "x")))
    }
}
