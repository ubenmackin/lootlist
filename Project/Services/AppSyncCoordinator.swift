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

/// Terminal outcome of a sync pass. Surfaced via the `.syncDidComplete`
/// notification so background-fetch completion can report the real result
/// (`.newData`/`.noData`/`.failed`) instead of always claiming new data.
enum SyncOutcome: String, Sendable, Equatable {
    case changed
    case noChange
    case failed

    /// Notification userInfo key under which `.syncDidComplete` posts the outcome.
    static let userInfoKey = "syncOutcome"
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
        // Dual-path subscription strategy:
        // - Owner (private) database: use a zone-scoped CKRecordZoneSubscription so
        //   change notifications only fire for this family's zone, avoiding spurious
        //   incrementalSync calls triggered by unrelated zones in the same database.
        // - Participant (shared) database: keep using CKDatabaseSubscription because
        //   CKRecordZoneSubscription may not work with shared zones; participants
        //   observe the shared zone through a database-level subscription instead.
        let subscription: CKSubscription = if database.databaseScope == .shared {
            CKDatabaseSubscription(subscriptionID: "lootlist-changes-\(zoneID.zoneName)")
        } else {
            CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: "lootlist-changes-\(zoneID.zoneName)")
        }

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
        // Route by notification type rather than concrete class, because the two
        // subscription strategies emit different notification families:
        // - Owner (private-database) path: CKRecordZoneSubscription generates
        //   CKRecordZoneNotification events (a CKQueryNotification subclass) with
        //   notificationType == .recordZone — NOT CKDatabaseNotification.
        // - Participant (shared-database) path: CKDatabaseSubscription generates
        //   CKDatabaseNotification events with notificationType == .database.
        // Both must reach handleDatabaseChange so push-driven incrementalSync
        // fires for either role; only genuinely unexpected substrate changes
        // (e.g. .readNotification) should be dropped.
        let subscriptionID: String
        switch notification.notificationType {
        case .database:
            guard let databaseNotification = notification as? CKDatabaseNotification else {
                logger.warning("CloudKit .database notification with unexpected concrete type (\(String(describing: type(of: notification)))) — dropping it")
                return
            }
            subscriptionID = databaseNotification.subscriptionID ?? "unknown"
        case .recordZone:
            // CKRecordZoneNotification is a CKQueryNotification subclass; cast
            // permissively so a future concrete variant still gets forwarded.
            guard let queryNotification = notification as? CKQueryNotification else {
                logger.warning("CloudKit .recordZone notification with unexpected concrete type (\(String(describing: type(of: notification)))) — dropping it")
                return
            }
            subscriptionID = queryNotification.subscriptionID ?? "unknown"
            if let zoneNotification = notification as? CKRecordZoneNotification,
               let zoneID = zoneNotification.recordZoneID
            {
                logger.debug("CloudKit record-zone change notification received for zone \(zoneID.zoneName, privacy: .private)")
            }
        case .query:
            guard let queryNotification = notification as? CKQueryNotification else {
                logger.warning("CloudKit .query notification with unexpected concrete type (\(String(describing: type(of: notification)))) — dropping it")
                return
            }
            subscriptionID = queryNotification.subscriptionID ?? "unknown"
        default:
            // Truly unexpected substrate change (e.g. .readNotification, or a
            // type introduced by a future SDK): drop it loudly rather than
            // failing silently.
            logger.warning("Received an unhandled CloudKit notification (\(String(describing: type(of: notification)))) — dropping it")
            return
        }

        logger.debug("CloudKit change notification received for subscription: \(subscriptionID, privacy: .private)")
        #if DEBUG
            let subID = subscriptionID
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
