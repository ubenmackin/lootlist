//
//  AppSyncCoordinator.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import Observation
import os

extension Notification.Name {
    static let cloudKitNotificationReceived = Notification.Name("cloudKitNotificationReceived")
    static let cloudKitShareAccepted = Notification.Name("cloudKitShareAccepted")
    static let syncDidComplete = Notification.Name("syncDidComplete")
}

@MainActor
@Observable
final class AppSyncCoordinator {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "AppSync")

    // MARK: - Sync Events

    enum SyncEvent: Sendable {
        case recordChanged(subscriptionID: String)
        case shareAccepted(shareID: CKRecord.ID)
        case zoneReset
    }

    private var continuations: [UUID: AsyncStream<SyncEvent>.Continuation] = [:]

    init() {
        startNotificationListeners()
    }

    private func startNotificationListeners() {
        Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .cloudKitNotificationReceived) {
                guard let self, let ckNotification = notification.object as? CKNotification else { continue }
                handleNotification(ckNotification)
            }
        }

        Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .cloudKitShareAccepted) {
                guard let self, let metadata = notification.object as? CKShare.Metadata else { continue }
                handleShareAcceptance(shareMetadata: metadata)
            }
        }
    }

    func registerSubscriptions(for zoneID: CKRecordZone.ID, in database: CKDatabase) async {
        let subscription = CKDatabaseSubscription(subscriptionID: "lootlist-changes-\(zoneID.zoneName)")

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        do {
            _ = try await database.save(subscription)
            logger.info("CloudKit subscription registered for zone \(zoneID.zoneName, privacy: .private)")
        } catch {
            logger.error("Failed to register CloudKit subscription: \(error, privacy: .private)")
        }
    }

    func removeSubscriptions(from database: CKDatabase) async {
        do {
            let subscriptions = try await database.allSubscriptions()
            for sub in subscriptions {
                try await database.deleteSubscription(withID: sub.subscriptionID)
            }
            logger.info("All CloudKit subscriptions removed")
        } catch {
            logger.error("Failed to remove CloudKit subscriptions: \(error, privacy: .private)")
        }
    }

    func handleNotification(_ notification: CKNotification) {
        guard let databaseNotification = notification as? CKDatabaseNotification else { return }

        let subscriptionID = databaseNotification.subscriptionID ?? "unknown"
        logger.debug("CloudKit change notification received for subscription: \(subscriptionID, privacy: .private)")
        #if DEBUG
            let subID = databaseNotification.subscriptionID ?? "nil"
            let notifType = String(describing: type(of: notification))
            logger.info("[DEBUG] handleNotification subscriptionID=\(subID, privacy: .private) notificationType=\(notifType, privacy: .public)")
        #endif

        handleDatabaseChange(subscriptionID: subscriptionID)
    }

    func handleDatabaseChange(subscriptionID: String) {
        for (_, continuation) in continuations {
            continuation.yield(.recordChanged(subscriptionID: subscriptionID))
        }
    }

    func handleShareAcceptance(shareMetadata: CKShare.Metadata) {
        let shareID = shareMetadata.share.recordID
        logger.info("CKShare acceptance notification received for share: \(shareID.recordName, privacy: .private)")

        for (_, continuation) in continuations {
            continuation.yield(.shareAccepted(shareID: shareID))
        }
    }

    func subscribe() -> (AsyncStream<SyncEvent>, UUID) {
        let id = UUID()
        let stream = AsyncStream<SyncEvent> { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.unsubscribe(id: id)
                }
            }
        }
        return (stream, id)
    }

    func unsubscribe(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    func notifyZoneReset() {
        for (_, continuation) in continuations {
            continuation.yield(.zoneReset)
        }
    }

    /// Test-only helper that injects a `.shareAccepted` event directly
    /// through the coordinator stream without requiring a real
    /// `CKShare.Metadata` object.  Mirrors `notifyZoneReset()`.
    func notifyShareAccepted(shareID: CKRecord.ID) {
        for (_, continuation) in continuations {
            continuation.yield(.shareAccepted(shareID: shareID))
        }
    }
}
