import CloudKit
import Foundation

enum CloudKitServiceError: Error, Equatable, Sendable {
    case underlying(String)

    case accountUnavailable

    case notFound(String)

    case retryable(attempt: Int, code: Int?)

    case exhaustedBudget(attempt: Int)

    case networkUnavailable

    case zoneSetupFailed(String)

    case subscriptionSetupFailed([String: String])

    case invalidArguments(String)

    case shareFailed(String)
}

actor SubscriptionManager {
    private(set) var activeSubscriptions: Set<String> = []
    private var changeContinuations:
        [String: [UUID: AsyncStream<[CKRecord]>.Continuation]] = [:]
    /// Tracks consumer IDs that were cancelled before registration completed.
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

    /// Atomically registers a continuation, guarding against cancellation
    /// that arrived before this call. If the consumer already cancelled,
    /// the continuation is finished immediately instead of being stored.
    func registerContinuation(_ continuation: AsyncStream<[CKRecord]>.Continuation,
                              for recordType: String,
                              consumerID: UUID)
    {
        if cancelledBeforeRegistration.remove(consumerID) != nil {
            // Consumer cancelled before we could register — finish and discard.
            continuation.finish()
            return
        }
        changeContinuations[recordType, default: [:]][consumerID] = continuation
    }

    /// Removes a continuation for a consumer. If the consumer hasn't been
    /// registered yet (cancellation arrived first), records it so that
    /// `registerContinuation` can short-circuit.
    func unregisterContinuation(for recordType: String, consumerID: UUID) {
        if changeContinuations[recordType]?.removeValue(forKey: consumerID) != nil {
            if changeContinuations[recordType]?.isEmpty == true {
                changeContinuations[recordType] = nil
            }
        } else {
            // Registration hasn't happened yet — mark for cancellation.
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
final class CloudKitService {
    private let container: CKContainer

    /// The database used for standard CRUD. Defaults to the private database.
    /// Downstream services should call `database(isOwner:)` to route correctly.
    let database: CKDatabase

    /// Private database — used by zone owners (Guild Masters) for zone creation,
    /// record saves, and CKShare management.
    let privateDatabase: CKDatabase

    /// Shared database — used by share participants (Heroes) for reading/writing
    /// family data that has been shared with them via CKShare.
    let sharedDatabase: CKDatabase

    let defaultZoneID: CKRecordZone.ID

    private let subscriptionManager = SubscriptionManager()

    var activeSubscriptions: Set<String> {
        get async {
            await subscriptionManager.activeSubscriptions
        }
    }

    init(container: CKContainer = .default(),
         zoneID: CKRecordZone.ID = CKRecordZone.ID(zoneName: "LootListZone",
                                                   ownerName: CKCurrentUserDefaultName))
    {
        self.container = container
        privateDatabase = container.privateCloudDatabase
        sharedDatabase = container.sharedCloudDatabase
        // Default database is private; callers should use database(isOwner:)
        // for context-aware routing.
        database = container.privateCloudDatabase
        defaultZoneID = zoneID
    }

    // MARK: - Active Family Context

    /// The zone ID for the currently active family. Set after family creation or
    /// joining. When set, CRUD operations that omit an explicit zone will use
    /// this zone instead of `defaultZoneID`.
    var activeFamilyZoneID: CKRecordZone.ID?

    /// Whether the current user owns the active family zone.
    /// - `true` → operations target `privateCloudDatabase`
    /// - `false` → operations target `sharedCloudDatabase`
    var activeIsOwner: Bool = true

    /// The database for the active family context.
    var activeFamilyDatabase: CKDatabase {
        database(isOwner: activeIsOwner)
    }

    /// The zone to use when no explicit zone is passed to CRUD methods.
    var resolvedZoneID: CKRecordZone.ID {
        activeFamilyZoneID ?? defaultZoneID
    }

    /// Returns the correct database based on whether the current user owns the zone.
    /// - Zone owners (Guild Masters) use `privateCloudDatabase`.
    /// - Share participants (Heroes) use `sharedCloudDatabase`.
    func database(isOwner: Bool) -> CKDatabase {
        isOwner ? privateDatabase : sharedDatabase
    }

    func save<T: CloudKitRecord>(_ model: T,
                                 in zoneID: CKRecordZone.ID? = nil,
                                 using db: CKDatabase? = nil) async throws -> T
    {
        let zone = zoneID ?? resolvedZoneID
        let targetDB = db ?? activeFamilyDatabase

        let source = model.toRecord()
        let targetID = CKRecord.ID(recordName: source.recordID.recordName, zoneID: zone)

        var recordToSave: CKRecord
        if let existing = try? await targetDB.record(for: targetID) {
            recordToSave = existing
        } else {
            recordToSave = CKRecord(recordType: T.recordType, recordID: targetID)
        }

        for key in source.allKeys() {
            recordToSave[key] = source[key]
        }

        let saved: CKRecord = try await retrying {
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
        return try T(record: saved)
    }

    func fetch<T: CloudKitRecord>(_: T.Type,
                                  id: CKRecord.ID,
                                  using db: CKDatabase? = nil) async throws -> T
    {
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
        let zone = zoneID ?? resolvedZoneID
        let targetDB = db ?? activeFamilyDatabase
        let query = CKQuery(recordType: type.recordType, predicate: predicate)
        query.sortDescriptors = sortDescriptors

        let (matchResults, _) = try await retrying {
            try await targetDB.records(matching: query,
                                       inZoneWith: zone,
                                       resultsLimit: CKQueryOperation.maximumResults)
        }
        var records: [CKRecord] = []
        for match in matchResults {
            switch match.1 {
            case let .success(record):
                records.append(record)
            case let .failure(error):
                throw wrapError(error)
            }
        }
        return try records.map { try T(record: $0) }
    }

    func deleteZone(_ zoneID: CKRecordZone.ID) async throws {
        let pvtDB = privateDatabase
        _ = try await retrying {
            try await pvtDB.deleteRecordZone(withID: zoneID)
        }
    }

    /// Creates a custom record zone in the **private** database.
    /// Custom zones can only be created in privateCloudDatabase; attempting to
    /// create one in sharedCloudDatabase causes CKError.invalidArguments.
    func ensureZoneExists(_ zoneID: CKRecordZone.ID) async throws {
        let pvtDB = privateDatabase
        do {
            _ = try await retrying {
                try await pvtDB.recordZone(for: zoneID)
            }

        } catch let error as CloudKitServiceError {
            switch error {
            case .notFound:
                let zone = CKRecordZone(zoneID: zoneID)
                do {
                    _ = try await retrying { () -> CKRecordZone in
                        try await withCheckedThrowingContinuation { continuation in
                            pvtDB.save(zone) { zone, error in
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

    // MARK: - CKShare Support

    /// Creates a `CKShare` for the given root record ID in the private database.
    /// The root record must already be saved in a custom zone in `privateCloudDatabase`.
    func createShare(for rootRecordID: CKRecord.ID) async throws -> CKShare {
        let pvtDB = privateDatabase
        let serverRoot = try await retrying {
            try await pvtDB.record(for: rootRecordID)
        }

        let share = CKShare(rootRecord: serverRoot)
        share[CKShare.SystemFieldKey.title] = (serverRoot["name"] as? String) ?? "Family Guild"
        share.publicPermission = .readOnly

        let operation = CKModifyRecordsOperation(
            recordsToSave: [serverRoot, share],
            recordIDsToDelete: nil
        )
        operation.isAtomic = true

        return try await withCheckedThrowingContinuation { continuation in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: share)
                case let .failure(error):
                    continuation.resume(throwing: CloudKitServiceError.shareFailed(
                        "Failed to create share: \(error)"
                    ))
                }
            }
            pvtDB.add(operation)
        }
    }

    /// Fetches an existing CKShare URL for the zone, or creates a new CKShare if one does not exist.
    func fetchOrCreateShareURL(in zoneID: CKRecordZone.ID, rootRecordID: CKRecord.ID) async throws -> URL {
        if let existingURL = try? await fetchShareURL(in: zoneID) {
            return existingURL
        }
        let share = try await createShare(for: rootRecordID)
        guard let url = share.url else {
            throw CloudKitServiceError.shareFailed("Share created but URL was nil")
        }
        return url
    }

    /// Accepts a CKShare invitation. After acceptance the shared zone appears
    /// in `sharedCloudDatabase`.
    func acceptShare(metadata: CKShare.Metadata) async throws {
        let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.acceptSharesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case let .failure(error):
                    continuation.resume(throwing: CloudKitServiceError.shareFailed(
                        "Failed to accept share: \(error)"
                    ))
                }
            }
            container.add(operation)
        }
    }

    /// Discovers all shared record zones available to the current user in
    /// `sharedCloudDatabase`. Used by Heroes to find the family zone after
    /// accepting a CKShare.
    func fetchSharedZones() async throws -> [CKRecordZone] {
        let sharedDB = sharedDatabase
        return try await sharedDB.allRecordZones()
    }

    /// Fetches the CKShare URL for a given record zone. Used by Guild Masters
    /// to retrieve the invitation link after creating a family.
    func fetchShareURL(in zoneID: CKRecordZone.ID) async throws -> URL? {
        let pvtDB = privateDatabase
        let predicate = NSPredicate(value: true)
        let query = CKQuery(recordType: "cloudkit.share", predicate: predicate)

        let (matchResults, _) = try await pvtDB.records(
            matching: query,
            inZoneWith: zoneID,
            resultsLimit: 1
        )

        for (_, result) in matchResults {
            if case let .success(record) = result,
               let share = record as? CKShare
            {
                return share.url
            }
        }
        return nil
    }

    /// Fetches the current user's CloudKit record ID.
    func currentUserRecordID() async throws -> CKRecord.ID {
        try await container.userRecordID()
    }

    func setupSubscriptions(for recordTypes: [String],
                            in zoneID: CKRecordZone.ID,
                            using db: CKDatabase? = nil) async throws
    {
        let targetDB = db ?? activeFamilyDatabase
        var failures: [String: String] = [:]

        let existing = await subscriptionManager.activeSubscriptions

        for recordType in recordTypes {
            let subID = stableSubscriptionID(for: recordType, in: zoneID)
            if existing.contains(subID) {
                continue
            }

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
                _ = try await retrying { () -> CKSubscription in
                    try await withCheckedThrowingContinuation { continuation in
                        targetDB.save(subscription) { subscription, error in
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
                await subscriptionManager.addSubscription(subID)
            } catch {
                failures[recordType] = "\(error)"
            }
        }

        if !failures.isEmpty {
            throw CloudKitServiceError.subscriptionSetupFailed(failures)
        }
    }

    func tearDownSubscription(for recordType: String,
                              in zoneID: CKRecordZone.ID,
                              using db: CKDatabase? = nil) async throws
    {
        let targetDB = db ?? activeFamilyDatabase
        let subID = stableSubscriptionID(for: recordType, in: zoneID)
        do {
            _ = try await retrying {
                try await targetDB.deleteSubscription(withID: subID)
            }
            await subscriptionManager.removeSubscription(subID)
        } catch let error as CloudKitServiceError {
            switch error {
            case .notFound:
                await subscriptionManager.removeSubscription(subID)
            default:
                throw error
            }
        }
    }

    private func stableSubscriptionID(for recordType: String,
                                      in zoneID: CKRecordZone.ID) -> String
    {
        "\(recordType):\(zoneID.zoneName):\(zoneID.ownerName)"
    }

    func changes(for recordType: String) async -> AsyncStream<[CKRecord]> {
        let (stream, continuation) = AsyncStream<[CKRecord]>.makeStream()

        let consumerID = UUID()
        let manager = subscriptionManager

        // Await registration synchronously so the continuation is visible
        // to broadcastChange before the stream is returned to the caller.
        await manager.registerContinuation(continuation, for: recordType, consumerID: consumerID)

        continuation.onTermination = { @Sendable _ in
            Task {
                await manager.unregisterContinuation(for: recordType, consumerID: consumerID)
            }
        }

        return stream
    }

    func broadcastChange(for recordType: String,
                         in zoneID: CKRecordZone.ID? = nil,
                         using db: CKDatabase? = nil) async
    {
        let continuations = await subscriptionManager.continuations(for: recordType)
        guard !continuations.isEmpty else {
            return
        }

        let targetDB = db ?? activeFamilyDatabase
        do {
            let zone = zoneID ?? resolvedZoneID
            let query = CKQuery(recordType: recordType,
                                predicate: NSPredicate(value: true))
            let (matchResults, _) = try await retrying {
                try await targetDB.records(matching: query,
                                           inZoneWith: zone,
                                           resultsLimit: CKQueryOperation.maximumResults)
            }
            let records: [CKRecord] = matchResults.compactMap { match in
                if case let .success(record) = match.1 {
                    return record
                }
                return nil
            }
            for continuation in continuations {
                continuation.yield(records)
            }
        } catch {
            for continuation in continuations {
                continuation.finish()
            }
            await subscriptionManager.clearContinuations(for: recordType)
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
                    .networkFailure
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
            .notFound("serverRecordChanged")
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
