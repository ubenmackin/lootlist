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

    case retryable(attempt: Int, code: Int?)

    case exhaustedBudget(attempt: Int)

    case networkUnavailable

    case zoneSetupFailed(String)

    case subscriptionSetupFailed([String: String])

    case invalidArguments(String)

    case shareFailed(String)

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
        case let .notFound(details):
            "Requested record was not found (\(details))."
        case .serverRecordChanged:
            "Another device modified this record. Refresh to see the latest."
        case let .retryable(_, code):
            "CloudKit service is temporarily busy (code: \(code ?? 0))."
        case .exhaustedBudget:
            "CloudKit operation timed out after multiple retries."
        case let .zoneSetupFailed(msg):
            "Failed to set up family CloudKit zone: \(msg)"
        case .subscriptionSetupFailed:
            "Failed to configure CloudKit subscriptions."
        case let .invalidArguments(msg):
            "Invalid arguments for CloudKit operation: \(msg)"
        case let .shareFailed(msg):
            "iCloud share operation failed: \(msg)"
        case let .underlying(msg):
            "CloudKit error: \(msg)"
        case let .paginationExhausted(pageBudget):
            "CloudKit query pagination exceeded \(pageBudget) pages without a termination signal."
        }
    }
}

actor SubscriptionManager {
    private(set) var activeSubscriptions: Set<String> = []
    private var changeContinuations:
        [String: [UUID: AsyncStream<[CKRecord]>.Continuation]] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []

    func hasSubscription(_ id: String) -> Bool {
        activeSubscriptions.contains(id)
    }

    func addSubscription(_ id: String) {
        activeSubscriptions.insert(id)
    }

    func removeSubscription(_ id: String) {
        activeSubscriptions.remove(id)
    }

    func registerContinuation(_ continuation: AsyncStream<[CKRecord]>.Continuation,
                              for recordType: String,
                              consumerID: UUID)
    {
        if cancelledBeforeRegistration.remove(consumerID) != nil {
            continuation.finish()
            return
        }
        changeContinuations[recordType, default: [:]][consumerID] = continuation
    }

    func unregisterContinuation(for recordType: String, consumerID: UUID) {
        if changeContinuations[recordType]?.removeValue(forKey: consumerID) != nil {
            if changeContinuations[recordType]?.isEmpty == true {
                changeContinuations[recordType] = nil
            }
        } else {
            cancelledBeforeRegistration.insert(consumerID)
        }
    }

    func continuations(for recordType: String) -> [AsyncStream<[CKRecord]>.Continuation] {
        Array((changeContinuations[recordType] ?? [:]).values)
    }

    func clearContinuations(for recordType: String) {
        changeContinuations[recordType] = nil
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

    var isTestingOrMocking: Bool {
        TestEnvironment.isRunningUnitOrUITests || !mockRecords.isEmpty
    }

    var database: CKDatabase {
        privateDatabase
    }

    var privateDatabase: CKDatabase {
        if let cachedPrivateDatabase {
            return cachedPrivateDatabase
        }
        let db = container.privateCloudDatabase
        cachedPrivateDatabase = db
        return db
    }

    var sharedDatabase: CKDatabase {
        if let cachedSharedDatabase {
            return cachedSharedDatabase
        }
        let db = container.sharedCloudDatabase
        cachedSharedDatabase = db
        return db
    }

    let defaultZoneID: CKRecordZone.ID

    let subscriptionManager = SubscriptionManager()

    var activeSubscriptions: Set<String> {
        get async {
            await subscriptionManager.activeSubscriptions
        }
    }

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

    var activeFamilyDatabase: CKDatabase {
        database(isOwner: activeIsOwner)
    }

    var resolvedZoneID: CKRecordZone.ID {
        activeFamilyZoneID ?? defaultZoneID
    }

    func database(isOwner: Bool) -> CKDatabase {
        isOwner ? privateDatabase : sharedDatabase
    }

    // MARK: - In-Memory Mock Record Storage for Testing & Screenshots

    var mockRecords: [String: CKRecord] = [:]

    func seedMockRecords(_ models: [any CloudKitRecord]) {
        for model in models {
            let record = model.toRecord()
            mockRecords[record.recordID.recordName] = record
        }
    }

    func save<T: CloudKitRecord>(_ model: T,
                                 in zoneID: CKRecordZone.ID? = nil,
                                 using db: CKDatabase? = nil) async throws -> T
    {
        if isTestingOrMocking {
            let source = model.toRecord()
            let recordToSave = CKRecord(recordType: T.recordType, recordID: source.recordID)
            for key in source.allKeys() {
                recordToSave[key] = source[key]
            }
            mockRecords[source.recordID.recordName] = recordToSave
            return try T(record: recordToSave)
        }

        let zone = zoneID ?? resolvedZoneID
        let targetDB = db ?? activeFamilyDatabase

        let source = model.toRecord()
        let targetID: CKRecord.ID = {
            if source.recordID.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName {
                return source.recordID
            }
            return CKRecord.ID(recordName: source.recordID.recordName, zoneID: zone)
        }()

        let recordToSave: CKRecord
        do {
            recordToSave = try await targetDB.record(for: targetID)
        } catch let error as CKError where error.code == .unknownItem {
            recordToSave = CKRecord(recordType: T.recordType, recordID: targetID)
        } catch {
            throw error // Propagate network errors rather than silently creating duplicates
        }

        if T.recordType != Family.recordType {
            if let familyRef = source["family"] as? CKRecord.Reference {
                let parentID = CKRecord.ID(recordName: familyRef.recordID.recordName, zoneID: zone)
                recordToSave.setParent(parentID)
            } else if let parent = source.parent {
                let parentID = CKRecord.ID(recordName: parent.recordID.recordName, zoneID: zone)
                recordToSave.setParent(parentID)
            }
        }

        for key in source.allKeys() {
            recordToSave[key] = source[key]
        }

        let dbLabel = targetDB == sharedDatabase ? "sharedDatabase" : "privateDatabase"
        let zoneName = zone.zoneName
        let ownerName = zone.ownerName
        let parentName = recordToSave.parent?.recordID.recordName ?? "none"
        logger.info("Save \(T.recordType, privacy: .public) id=\(recordToSave.recordID.recordName, privacy: .private) zone=\(zoneName, privacy: .private)")
        logger.info("owner=\(ownerName, privacy: .private) db=\(dbLabel, privacy: .public) parent=\(parentName, privacy: .private)")

        let saved: CKRecord
        do {
            saved = try await retrying {
                try await withCheckedThrowingContinuation { continuation in
                    targetDB.save(recordToSave) { record, error in
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
        } catch {
            logger.error("Save failed for \(T.recordType, privacy: .public) (\(recordToSave.recordID.recordName, privacy: .private)): \(error, privacy: .private)")
            throw error
        }
        logger.info("Saved \(T.recordType, privacy: .public) (\(saved.recordID.recordName, privacy: .private))")
        return try T(record: saved)
    }

    func fetch<T: CloudKitRecord>(_: T.Type,
                                  id: CKRecord.ID,
                                  using db: CKDatabase? = nil) async throws -> T
    {
        if isTestingOrMocking {
            if let record = mockRecords[id.recordName] {
                return try T(record: record)
            }
            throw CloudKitServiceError.notFound(id.recordName)
        }

        let targetDB = db ?? activeFamilyDatabase
        let record = try await retrying {
            try await targetDB.record(for: id)
        }
        return try T(record: record)
    }

    func delete(_ recordID: CKRecord.ID,
                in zoneID: CKRecordZone.ID? = nil,
                using db: CKDatabase? = nil) async throws
    {
        if isTestingOrMocking {
            mockRecords.removeValue(forKey: recordID.recordName)
            return
        }

        let targetDB = db ?? activeFamilyDatabase
        let id = CKRecord.ID(recordName: recordID.recordName,
                             zoneID: zoneID ?? recordID.zoneID)
        _ = try await retrying {
            try await targetDB.deleteRecord(withID: id)
        }
    }

    func query<T: CloudKitRecord>(_ type: T.Type,
                                  predicate: NSPredicate,
                                  in zoneID: CKRecordZone.ID? = nil,
                                  sortDescriptors: [NSSortDescriptor]? = nil,
                                  using db: CKDatabase? = nil) async throws -> [T]
    {
        if isTestingOrMocking {
            let matching = mockRecords.values.filter { record in
                guard record.recordType == T.recordType else { return false }
                return evaluateMockPredicate(predicate, record: record)
            }
            let sorted = sortMockRecords(Array(matching), sortDescriptors: sortDescriptors)
            return try sorted.map { try T(record: $0) }
        }

        let zone = zoneID ?? resolvedZoneID
        let targetDB = db ?? activeFamilyDatabase
        let query = CKQuery(recordType: type.recordType, predicate: predicate)
        query.sortDescriptors = sortDescriptors

        var allMatchResults: [(CKRecord.ID, Result<CKRecord, Error>)] = []
        let maximumResults = CKQueryOperation.maximumResults

        let (firstPageResults, firstCursor) = try await retrying {
            try await targetDB.records(matching: query,
                                       inZoneWith: zone,
                                       resultsLimit: maximumResults)
        }
        allMatchResults.append(contentsOf: firstPageResults)
        var cursor: CKQueryOperation.Cursor? = firstCursor

        var pageCount = 1
        while let nextCursor = cursor {
            guard pageCount < Self.maxFetchPages else {
                throw CloudKitServiceError.paginationExhausted(pageBudget: Self.maxFetchPages)
            }
            let (pageResults, nextPageCursor) = try await retrying {
                try await targetDB.records(continuingMatchFrom: nextCursor,
                                           resultsLimit: maximumResults)
            }
            allMatchResults.append(contentsOf: pageResults)
            cursor = nextPageCursor
            pageCount += 1
        }

        var records: [CKRecord] = []
        for match in allMatchResults {
            switch match.1 {
            case let .success(record):
                records.append(record)
            case let .failure(error):
                throw wrapError(error)
            }
        }
        return try records.map { try T(record: $0) }
    }

    func fetchZoneChanges(
        in zoneID: CKRecordZone.ID? = nil,
        since token: CKServerChangeToken? = nil,
        using db: CKDatabase? = nil
    ) async throws -> ZoneChangesResult {
        if isTestingOrMocking {
            return ZoneChangesResult(
                changedRecords: Array(mockRecords.values),
                deletedRecordIDs: [],
                newToken: nil,
                moreComing: false
            )
        }

        let zone = zoneID ?? resolvedZoneID
        let targetDB = db ?? activeFamilyDatabase

        return try await retrying {
            var changedRecords: [CKRecord] = []
            var deletedRecordIDs: [(recordID: CKRecord.ID, recordType: String)] = []
            var newToken: CKServerChangeToken?
            var moreComing = false

            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            config.previousServerChangeToken = token

            let op = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone], configurationsByRecordZoneID: [zone: config])

            op.recordWasChangedBlock = { _, result in
                if case let .success(record) = result {
                    changedRecords.append(record)
                }
            }

            op.recordWithIDWasDeletedBlock = { recordID, recordType in
                deletedRecordIDs.append((recordID, recordType))
            }

            op.recordZoneFetchResultBlock = { _, result in
                if case let .success((serverChangeToken, _, hasMoreComing)) = result {
                    newToken = serverChangeToken
                    moreComing = hasMoreComing
                }
            }

            return try await withCheckedThrowingContinuation { continuation in
                op.fetchRecordZoneChangesResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume(returning: ZoneChangesResult(
                            changedRecords: changedRecords,
                            deletedRecordIDs: deletedRecordIDs,
                            newToken: newToken,
                            moreComing: moreComing
                        ))
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                }
                targetDB.add(op)
            }
        }
    }

    private func evaluateMockPredicate(_ predicate: NSPredicate, record: CKRecord) -> Bool {
        let fmt = predicate.predicateFormat
        if fmt == "TRUEPRED" || fmt == "1 == 1" {
            return true
        }

        if predicate.evaluate(with: record) {
            return true
        }

        let referenceKeys = ["family", "profile", "assignee", "completedBy", "template", "quest"]
        for key in referenceKeys {
            if fmt.contains("\(key) ==") || fmt.contains("\(key) =") {
                if let ref = record[key] as? CKRecord.Reference {
                    return fmt.contains(ref.recordID.recordName)
                }
            }
        }

        if fmt.contains("recordID IN") {
            return fmt.contains(record.recordID.recordName)
        }
        return true
    }

    private func sortMockRecords(_ records: [CKRecord], sortDescriptors: [NSSortDescriptor]?) -> [CKRecord] {
        guard let sortDescriptors, !sortDescriptors.isEmpty else { return records }
        var result = records
        for descriptor in sortDescriptors.reversed() {
            guard let key = descriptor.key else { continue }
            let ascending = descriptor.ascending
            result.sort { lhs, rhs -> Bool in
                let valA = lhs[key]
                let valB = rhs[key]
                if let dA = valA as? Date, let dB = valB as? Date {
                    return ascending ? dA < dB : dA > dB
                }
                if let sA = valA as? String, let sB = valB as? String {
                    return ascending ? sA < sB : sA > sB
                }
                if let nA = valA as? Double, let nB = valB as? Double {
                    return ascending ? nA < nB : nA > nB
                }
                if let iA = valA as? Int, let iB = valB as? Int {
                    return ascending ? iA < iB : iA > iB
                }
                return false
            }
        }
        return result
    }

    func currentUserRecordID() async throws -> CKRecord.ID {
        try await container.userRecordID()
    }

    func accountStatus() async throws -> CKAccountStatus {
        do {
            return try await container.accountStatus()
        } catch {
            throw wrapError(error)
        }
    }

    private static let maxRetries = 3

    /// Defensive upper bound on cursor pagination. CloudKit's contract is that a
    /// non-nil cursor always means more results exist, but if the server ever
    /// returns a non-nil cursor alongside an empty page we abort here rather
    /// than loop indefinitely.
    private static let maxFetchPages = 10000

    private static let backoffSchedule: [UInt64] = [
        500_000_000,
        1_500_000_000,
        4_000_000_000
    ]

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

                if attempt < Self.maxRetries,
                   let delayNanos = Self.backoffSchedule[safe: attempt - 1]
                {
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

    private func wrapError(_ error: Error) -> CloudKitServiceError {
        if let ckError = error as? CKError {
            return wrapCKError(ckError)
        }
        return .underlying(String(describing: error))
    }

    private func wrapCKError(_ error: CKError) -> CloudKitServiceError {
        switch error.code {
        case .zoneNotFound, .unknownItem, .constraintViolation:
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
