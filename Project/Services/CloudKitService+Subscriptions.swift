//
//  CloudKitService+Subscriptions.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

extension CloudKitService {
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

    func stableSubscriptionID(for recordType: String,
                              in zoneID: CKRecordZone.ID) -> String
    {
        "\(recordType):\(zoneID.zoneName):\(zoneID.ownerName)"
    }

    /// Registers an AsyncStream continuation with SubscriptionManager to receive live CloudKit record change updates.
    func changes(for recordType: String) async -> AsyncStream<[CKRecord]> {
        let (stream, continuation) = AsyncStream<[CKRecord]>.makeStream()

        let consumerID = UUID()
        let manager = subscriptionManager

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
}
