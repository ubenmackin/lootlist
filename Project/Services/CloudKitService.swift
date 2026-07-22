import Foundation
import CloudKit

enum CloudKitServiceError: Error, Equatable, Sendable {

    case underlying(String)

    case accountUnavailable

    case notFound(String)

    case retryable(attempt: Int, code: Int?)

    case exhaustedBudget(attempt: Int)

    case networkUnavailable

    case zoneSetupFailed(String)

    case subscriptionSetupFailed([String: String])
}

@Observable
final class CloudKitService: @unchecked Sendable {

    private let container: CKContainer

    let database: CKDatabase

    let defaultZoneID: CKRecordZone.ID

    private(set) var activeSubscriptions: Set<String> = []
    private let subscriptionLock = NSLock()

    private var changeContinuations:
        [String: [UUID: AsyncStream<[CKRecord]>.Continuation]] = [:]
    private let continuationLock = NSLock()

    init(container: CKContainer = .default(),
         zoneID: CKRecordZone.ID = CKRecordZone.ID(zoneName: "QuestLogZone",
                                                    ownerName: "__defaultOwner__")) {
        self.container = container
        self.database = container.sharedCloudDatabase
        self.defaultZoneID = zoneID
    }

    func save<T: CloudKitRecord>(_ model: T,
                                 in zoneID: CKRecordZone.ID? = nil) async throws -> T {
        let zone = zoneID ?? defaultZoneID

        let source = model.toRecord()
        let resolved = CKRecord(recordType: T.recordType,
                                 recordID: CKRecord.ID(recordName: source.recordID.recordName,
                                                        zoneID: zone))
        for key in source.allKeys() {
            if let value = source[key] {
                resolved[key] = value
            }
        }

        let saved: CKRecord = try await retrying { [database] in
            try await withCheckedThrowingContinuation { continuation in
                database.save(resolved) { record, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let record {
                        continuation.resume(returning: record)
                    } else {
                        continuation.resume(throwing: CKError(.internalError))
                    }
                }
            }
        }
        return try T(record: saved)
    }

    func fetch<T: CloudKitRecord>(_ type: T.Type,
                                  id: CKRecord.ID) async throws -> T {
        let record = try await retrying { [database] in
            try await database.record(for: id)
        }
        return try T(record: record)
    }

    func delete(_ recordID: CKRecord.ID,
                in zoneID: CKRecordZone.ID? = nil) async throws {
        let id = CKRecord.ID(recordName: recordID.recordName,
                              zoneID: zoneID ?? recordID.zoneID)
        _ = try await retrying { [database] in
            try await database.deleteRecord(withID: id)
        }
    }

    func query<T: CloudKitRecord>(_ type: T.Type,
                                  predicate: NSPredicate,
                                  in zoneID: CKRecordZone.ID? = nil,
                                  sortDescriptors: [NSSortDescriptor]? = nil) async throws -> [T] {
        let zone = zoneID ?? defaultZoneID
        let query = CKQuery(recordType: type.recordType, predicate: predicate)
        query.sortDescriptors = sortDescriptors

        let (matchResults, _) = try await retrying { [database] in
            try await database.records(matching: query,
                                         inZoneWith: zone,
                                         resultsLimit: CKQueryOperation.maximumResults)
        }
        var records: [CKRecord] = []
        for match in matchResults {
            switch match.1 {
            case .success(let record):
                records.append(record)
            case .failure(let error):
                throw wrapError(error)
            }
        }
        return try records.map { try T(record: $0) }
    }

    func ensureZoneExists(_ zoneID: CKRecordZone.ID) async throws {
        do {
            _ = try await retrying { [database] in
                try await database.recordZone(for: zoneID)
            }

        } catch let error as CloudKitServiceError {
            switch error {
            case .notFound:

                let zone = CKRecordZone(zoneID: zoneID)
                do {
                    _ = try await retrying { [database] () -> CKRecordZone in
                        try await withCheckedThrowingContinuation { continuation in
                            database.save(zone) { zone, error in
                                if let error {
                                    continuation.resume(throwing: error)
                                } else {
                                    guard let zone else {
                                        continuation.resume(throwing: CKError(.internalError))
                                        return
                                    }
                                    continuation.resume(returning: zone)
                                }
                            }
                        }
                    }
                } catch {
                    throw CloudKitServiceError.zoneSetupFailed(
                        "Failed to create zone \(zoneID.zoneName): \(error)"
                    )
                }
            default:
                throw error
            }
        }
    }

    func setupSubscriptions(for recordTypes: [String],
                            in zoneID: CKRecordZone.ID) async throws {
        var failures: [String: String] = [:]

        let existing = subscriptionLock.withLock { Set(activeSubscriptions) }

        for recordType in recordTypes {
            let subID = stableSubscriptionID(for: recordType, in: zoneID)
            if existing.contains(subID) { continue }

            let predicate = NSPredicate(value: true)
            let subscription = CKQuerySubscription(recordType: recordType,
                                                     predicate: predicate,
                                                     subscriptionID: subID)

            let info = CKSubscription.NotificationInfo()
            info.alertBody = "New \(recordType) activity in your family"
            info.shouldBadge = false
            info.shouldSendContentAvailable = true
            info.desiredKeys = ["family"]
            subscription.notificationInfo = info

            do {
                _ = try await retrying { [database] () -> CKSubscription in
                    try await withCheckedThrowingContinuation { continuation in
                        database.save(subscription) { subscription, error in
                            if let error {
                                continuation.resume(throwing: error)
                            } else {
                                guard let subscription else {
                                    continuation.resume(throwing: CKError(.internalError))
                                    return
                                }
                                continuation.resume(returning: subscription)
                            }
                        }
                    }
                }
                _ = subscriptionLock.withLock {
                    activeSubscriptions.insert(subID)
                }
            } catch {
                failures[recordType] = "\(error)"
            }
        }

        if !failures.isEmpty {
            throw CloudKitServiceError.subscriptionSetupFailed(failures)
        }
    }

    func tearDownSubscription(for recordType: String,
                              in zoneID: CKRecordZone.ID) async throws {
        let subID = stableSubscriptionID(for: recordType, in: zoneID)
        do {
            _ = try await retrying { [database] in
                try await database.deleteSubscription(withID: subID)
            }
            _ = subscriptionLock.withLock {
                activeSubscriptions.remove(subID)
            }
        } catch let error as CloudKitServiceError {
            switch error {
            case .notFound:

                _ = subscriptionLock.withLock {
                    activeSubscriptions.remove(subID)
                }
            default:
                throw error
            }
        }
    }

    private func stableSubscriptionID(for recordType: String,
                                       in zoneID: CKRecordZone.ID) -> String {
        "\(recordType):\(zoneID.zoneName):\(zoneID.ownerName)"
    }

    func changes(for recordType: String) -> AsyncStream<[CKRecord]> {
        let (stream, continuation) = AsyncStream<[CKRecord]>.makeStream()

        let consumerID = UUID()
        continuationLock.withLock {
            changeContinuations[recordType, default: [:]][consumerID] = continuation
        }

        continuation.onTermination = { @Sendable [weak self] _ in
            guard let self else { return }
            self.continuationLock.withLock {
                self.changeContinuations[recordType]?.removeValue(forKey: consumerID)
                if self.changeContinuations[recordType]?.isEmpty == true {
                    self.changeContinuations[recordType] = nil
                }
            }
        }

        return stream
    }

    func broadcastChange(for recordType: String,
                          in zoneID: CKRecordZone.ID? = nil) async {
        let continuations: [AsyncStream<[CKRecord]>.Continuation] = continuationLock.withLock {
            Array((changeContinuations[recordType] ?? [:]).values)
        }
        guard !continuations.isEmpty else {

            return
        }

        do {
            let zone = zoneID ?? defaultZoneID
            let query = CKQuery(recordType: recordType,
                                 predicate: NSPredicate(value: true))
            let (matchResults, _) = try await retrying { [database] in
                try await database.records(matching: query,
                                             inZoneWith: zone,
                                             resultsLimit: CKQueryOperation.maximumResults)
            }
            let records: [CKRecord] = matchResults.compactMap { match in
                if case .success(let record) = match.1 { return record }
                return nil
            }
            for continuation in continuations {
                continuation.yield(records)
            }
        } catch {

            for continuation in continuations {
                continuation.finish()
            }
            continuationLock.withLock {
                changeContinuations[recordType] = nil
            }
        }
    }

    func accountStatus() async throws -> CKAccountStatus {
        do {
            return try await container.accountStatus()
        } catch {
            throw wrapError(error)
        }
    }

    private static let maxRetries = 3

    private static let backoffSchedule: [UInt64] = [
        500_000_000,   
        1_500_000_000, 
        4_000_000_000  
    ]

    private func retrying<T>(_ operation: () async throws -> T) async throws -> T {
        var lastWrappedError: CloudKitServiceError?

        for attempt in 1...Self.maxRetries {
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
                ]

                guard retryableCodes.contains(error.code) else {

                    throw wrapCKError(error)
                }

                lastWrappedError = isNetwork
                    ? .networkUnavailable
                    : .retryable(attempt: attempt, code: error.code.rawValue)

                if attempt < Self.maxRetries,
                   let delayNanos = Self.backoffSchedule[safe: attempt - 1] {
                    try await Task.sleep(nanoseconds: delayNanos)
                    continue
                }
                throw CloudKitServiceError.exhaustedBudget(attempt: attempt)
            } catch let error as CloudKitServiceError {

                throw error
            } catch {

                lastWrappedError = .underlying("\(error)")
                if attempt < Self.maxRetries,
                   let delayNanos = Self.backoffSchedule[safe: attempt - 1] {
                    try await Task.sleep(nanoseconds: delayNanos)
                    continue
                }
                throw CloudKitServiceError.exhaustedBudget(attempt: attempt)
            }
        }

        throw lastWrappedError ?? CloudKitServiceError.exhaustedBudget(attempt: Self.maxRetries)
    }

    private func wrapError(_ error: Error) -> CloudKitServiceError {
        if let ckError = error as? CKError {
            return wrapCKError(ckError)
        }
        return .underlying(String(describing: error))
    }

    private func wrapCKError(_ error: CKError) -> CloudKitServiceError {
        switch error.code {
        case .zoneNotFound, .unknownItem, .constraintViolation:
            return .notFound("\(error.code.rawValue)")
        case .serverRecordChanged:

            return .notFound("serverRecordChanged")
        case .managedAccountRestricted, .notAuthenticated, .userDeletedZone:
            return .accountUnavailable
        case .networkUnavailable, .networkFailure:
            return .networkUnavailable
        case .zoneBusy, .serviceUnavailable, .requestRateLimited:
            return .retryable(attempt: 1, code: error.code.rawValue)
        default:
            return .underlying("\(error.code.rawValue)")
        }
    }
}

extension Array {

    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension NSLock {

    fileprivate func withLock<T>(_ block: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try block()
    }
}
