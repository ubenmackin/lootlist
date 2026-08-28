//
//  CloudKitService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import OSLog

enum CloudKitServiceError: Error, Equatable, Sendable, LocalizedError {
    case underlying(String)

    case accountUnavailable

    case notFound(String)

    case serverRecordChanged

    case changeTokenExpired

    case zoneNotFound

    case retryable(attempt: Int, code: Int?)

    case exhaustedBudget(attempt: Int)

    case networkUnavailable

    case zoneSetupFailed(String)

    case invalidArguments(String)

    case shareFailed(String)

    /// Accepting a share invitation failed. The underlying `CKError.Code` is preserved (when CloudKit
    /// supplied one) so callers can classify the failure symbolically — e.g.
    case shareAcceptFailed(code: CKError.Code?, message: String)

    /// Cursor pagination exceeded a sane page budget without CloudKit signaling
    /// completion (`cursor == nil`). Defensive guard against pathological infinite
    /// loops where CloudKit returns a non-nil cursor alongside an empty page.
    case paginationExhausted(pageBudget: Int)

    var errorDescription: String? {
        switch self {
        case .accountUnavailable:
            "iCloud account is unavailable or not authenticated. Please check Settings."
        case .networkUnavailable:
            "Network connection is unavailable."
        case .notFound:
            "The requested record could not be found."
        case .serverRecordChanged:
            "Another device modified this record. Refresh to see the latest."
        case .changeTokenExpired:
            "CloudKit change token has expired. Requesting full sync."
        case .zoneNotFound:
            "CloudKit record zone was not found."
        case let .retryable(_, code):
            "CloudKit service is temporarily busy (code: \(code ?? 0))."
        case .exhaustedBudget:
            "CloudKit operation timed out after multiple retries."
        case .zoneSetupFailed:
            "Could not set up the family CloudKit zone. Please try again."
        case .invalidArguments:
            "Invalid arguments for this operation. Please try again."
        case .shareFailed:
            "Could not create the iCloud share. Please try again."
        case .shareAcceptFailed:
            "Could not accept the share invitation."
        case .underlying:
            "Something went wrong. Please try again."
        case let .paginationExhausted(pageBudget):
            "CloudKit query pagination exceeded \(pageBudget) pages without a termination signal."
        }
    }
}

@MainActor
@Observable
class CloudKitService: CloudKitServiceProtocol {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "CloudKitService")

    private var containerStorage: CKContainer?

    static var defaultContainer: CKContainer {
        CKContainer(identifier: "iCloud.com.volcrypt.lootlist")
    }

    var container: CKContainer {
        if let containerStorage {
            return containerStorage
        }
        let targetContainer = CKContainer(identifier: "iCloud.com.volcrypt.lootlist")
        containerStorage = targetContainer
        return targetContainer
    }

    private var cachedPrivateDatabase: CKDatabase?
    private var cachedSharedDatabase: CKDatabase?

    var database: CKDatabase? {
        privateDatabase
    }

    var privateDatabase: CKDatabase? {
        if let cachedPrivateDatabase {
            return cachedPrivateDatabase
        }
        let db = container.privateCloudDatabase
        cachedPrivateDatabase = db
        return db
    }

    var sharedDatabase: CKDatabase? {
        if let cachedSharedDatabase {
            return cachedSharedDatabase
        }
        let db = container.sharedCloudDatabase
        cachedSharedDatabase = db
        return db
    }

    let defaultZoneID: CKRecordZone.ID

    init(container: CKContainer? = nil,
         zoneID: CKRecordZone.ID = CKRecordZone.ID(zoneName: "LootListZone",
                                                   ownerName: CKCurrentUserDefaultName))
    {
        if let container {
            containerStorage = container
            cachedPrivateDatabase = container.privateCloudDatabase
            cachedSharedDatabase = container.sharedCloudDatabase
        }
        defaultZoneID = zoneID
    }

    // MARK: - Active Family Context

    var activeFamilyZoneID: CKRecordZone.ID?
    var activeIsOwner: Bool = true

    var activeFamilyDatabase: CKDatabase? {
        database(isOwner: activeIsOwner)
    }

    var resolvedZoneID: CKRecordZone.ID {
        activeFamilyZoneID ?? defaultZoneID
    }

    func database(isOwner: Bool) -> CKDatabase? {
        isOwner ? privateDatabase : sharedDatabase
    }

    private static let maxRetries = AppConstants.CloudKit.maxRetries

    /// Defensive upper bound on cursor pagination. CloudKit's contract is that a non-nil cursor always
    /// means more results exist, but if the server ever returns a non-nil cursor alongside an empty page we
    static let maxFetchPages = AppConstants.CloudKit.maxFetchPages

    private static let backoffSchedule: [UInt64] = AppConstants.CloudKit.backoffScheduleNanos

    func retrying<T>(_ operation: () async throws -> T) async throws -> T {
        var lastWrappedError: CloudKitServiceError?

        for attempt in 1 ... Self.maxRetries {
            do {
                return try await operation()
            } catch let error as CKError {
                let isNetwork = (error.code == .networkUnavailable || error.code == .networkFailure)
                let retryableCodes: [CKError.Code] = [
                    .zoneBusy,
                    .serviceUnavailable,
                    .requestRateLimited,
                    .networkUnavailable,
                    .networkFailure,
                    .notAuthenticated
                ]

                guard retryableCodes.contains(error.code) else {
                    throw wrapCKError(error)
                }

                lastWrappedError = isNetwork
                    ? .networkUnavailable
                    : .retryable(attempt: attempt, code: error.code.rawValue)

                if attempt < Self.maxRetries {
                    // Server-supplied retry-after values are untrusted: negative or non-finite values would trap in the
                    // UInt64 conversion, and even a large-but-finite value can overflow at that same conversion, so
                    let maxScheduledNanos = Self.backoffSchedule.max() ?? 1_000_000_000
                    let maxScheduledSeconds = Double(maxScheduledNanos) / 1_000_000_000
                    let delayNanos: UInt64 = if let retryAfter = error.retryAfterSeconds,
                                                retryAfter.isFinite,
                                                retryAfter > 0
                    {
                        min(UInt64(min(retryAfter, maxScheduledSeconds) * 1_000_000_000),
                            maxScheduledNanos)
                    } else {
                        Self.backoffSchedule[safe: attempt - 1] ?? 1_000_000_000
                    }
                    try await Task.sleep(nanoseconds: delayNanos)
                    continue
                }
                throw CloudKitServiceError.exhaustedBudget(attempt: attempt)
            } catch let error as CloudKitServiceError {
                throw error
            } catch {
                // Non-retryable errors should propagate immediately.
                if error is CancellationError
                    || error is DecodingError
                    || error is EncodingError
                {
                    throw error
                }
                lastWrappedError = .underlying("\(error)")
                if attempt < Self.maxRetries,
                   let delayNanos = Self.backoffSchedule[safe: attempt - 1]
                {
                    try await Task.sleep(nanoseconds: delayNanos)
                    continue
                }
                throw CloudKitServiceError.exhaustedBudget(attempt: attempt)
            }
        }

        throw lastWrappedError ?? CloudKitServiceError.exhaustedBudget(attempt: Self.maxRetries)
    }

    func wrapError(_ error: Error) -> CloudKitServiceError {
        if let serviceError = error as? CloudKitServiceError {
            return serviceError
        }
        if let ckError = error as? CKError {
            return wrapCKError(ckError)
        }
        return .underlying(String(describing: error))
    }

    private func wrapCKError(_ error: CKError) -> CloudKitServiceError {
        switch error.code {
        case .changeTokenExpired:
            .changeTokenExpired
        case .zoneNotFound:
            .zoneNotFound
        case .unknownItem, .constraintViolation:
            .notFound("\(error.code.rawValue)")
        case .serverRecordChanged:
            .serverRecordChanged
        case .managedAccountRestricted, .notAuthenticated, .userDeletedZone:
            .accountUnavailable
        case .networkUnavailable, .networkFailure:
            .networkUnavailable
        case .zoneBusy, .serviceUnavailable, .requestRateLimited:
            .retryable(attempt: 1, code: error.code.rawValue)
        case .invalidArguments:
            .invalidArguments(error.localizedDescription)
        case .alreadyShared:
            .shareFailed("Record is already shared")
        case .operationCancelled:
            .underlying("operationCancelled")
        default:
            .underlying("\(error.code.rawValue)")
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }

    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
