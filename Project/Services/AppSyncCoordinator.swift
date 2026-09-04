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

    /// Last time a CloudKit change notification was delivered. Exposed read-only
    /// for the debug overlay to correlate silent-push health.
    private(set) var lastNotificationReceivedAt: Date?

    // MARK: - Sync Events

    enum SyncEvent: Sendable {
        case recordChanged(subscriptionID: String)
        case shareAccepted(shareID: CKRecord.ID)
        case zoneReset
    }

    private var continuations: [UUID: AsyncStream<SyncEvent>.Continuation] = [:]

    @ObservationIgnored private var cloudKitNotificationTask: Task<Void, Never>?
    @ObservationIgnored private var shareAcceptedTask: Task<Void, Never>?

    init() {
        startNotificationListeners()
    }

    private func startNotificationListeners() {
        if cloudKitNotificationTask == nil {
            cloudKitNotificationTask = Task { @MainActor [weak self] in
                await withTaskCancellationHandler {
                    for await notification in NotificationCenter.default.notifications(named: .cloudKitNotificationReceived) {
                        guard !Task.isCancelled else { break }
                        guard let self else { break }
                        guard let ckNotification = notification.object as? CKNotification else { continue }
                        self.handleNotification(ckNotification)
                    }
                } onCancel: {}
            }
        }

        if shareAcceptedTask == nil {
            shareAcceptedTask = Task { @MainActor [weak self] in
                await withTaskCancellationHandler {
                    for await notification in NotificationCenter.default.notifications(named: .cloudKitShareAccepted) {
                        guard !Task.isCancelled else { break }
                        guard let self else { break }
                        if let resolution = notification.object as? InvitationLinkResolution {
                            self.handleShareAcceptance(resolution)
                        }
                    }
                } onCancel: {}
            }
        }
    }

    /// Cancels stored notification listeners and clears references atomically.
    func stopNotificationListeners() {
        cloudKitNotificationTask?.cancel()
        cloudKitNotificationTask = nil
        shareAcceptedTask?.cancel()
        shareAcceptedTask = nil
    }

    deinit {
        cloudKitNotificationTask?.cancel()
        shareAcceptedTask?.cancel()
    }

    func registerSubscriptions(for zoneID: CKRecordZone.ID, in database: CKDatabase?) async {
        guard let database else { return }
        let subscriptionID = "lootlist-changes-\(zoneID.zoneName)"
        do {
            _ = try await database.subscription(for: subscriptionID)
            logger.debug("CloudKit subscription \(subscriptionID, privacy: .private) already registered")
            return
        } catch {
            logger.debug("Could not inspect CloudKit subscription \(subscriptionID, privacy: .private): \(error, privacy: .private)")
        }

        // Zone subscription for private database; database subscription for shared database.
        let subscription: CKSubscription = if database.databaseScope == .shared {
            CKDatabaseSubscription(subscriptionID: subscriptionID)
        } else {
            CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: subscriptionID)
        }

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        do {
            _ = try await database.save(subscription)
            logger.info("CloudKit subscription registered for zone \(zoneID.zoneName, privacy: .private)")
        } catch {
            if let ckError = error as? CKError, ckError.code == .serverRejectedRequest {
                logger.debug("CloudKit subscription already registered: \(subscriptionID, privacy: .private)")
                return
            }
            logger.error("Failed to register CloudKit subscription: \(error, privacy: .private)")
        }
    }

    func removeSubscriptions(from database: CKDatabase?) async {
        guard let database else { return }
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
        lastNotificationReceivedAt = Date()
        // Route by notificationType (.recordZone for private DB, .database for shared DB).
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
        lastNotificationReceivedAt = Date()
        if continuations.isEmpty {
            logger.warning("Sync event dropped: no observers for recordChanged \(subscriptionID, privacy: .private)")
        }
        for (_, continuation) in continuations {
            continuation.yield(.recordChanged(subscriptionID: subscriptionID))
        }
    }

    func handleShareAcceptance(_ resolution: InvitationLinkResolution) {
        // WHY: the share record lives in the family zone, so the snapshot's root zone rebuilds its identity without the acceptance object.
        guard let zoneID = resolution.zoneID else {
            logger
                .warning(
                    "Dropping share acceptance without zone identity for share: \(resolution.shareRecordName, privacy: .private) title: \(resolution.title ?? "unknown", privacy: .private)"
                )
            return
        }
        let shareID = CKRecord.ID(recordName: resolution.shareRecordName, zoneID: zoneID)
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
