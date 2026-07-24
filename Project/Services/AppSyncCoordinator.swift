import CloudKit
import Foundation
import Observation
import os

extension Notification.Name {
    static let cloudKitNotificationReceived = Notification.Name("cloudKitNotificationReceived")
    static let cloudKitShareAccepted = Notification.Name("cloudKitShareAccepted")
}

/// Coordinates CloudKit change notifications and CKShare acceptance events,
/// fanning them out to subscribers via an AsyncStream.
@MainActor
@Observable
final class AppSyncCoordinator {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "AppSync")

    // MARK: - Sync Events

    enum SyncEvent: Sendable {
        case recordChanged(recordTypeID: String)
        case shareAccepted(shareID: CKRecord.ID)
        case zoneReset
    }

    /// The stream continuations for subscribers
    private var continuations: [UUID: AsyncStream<SyncEvent>.Continuation] = [:]

    init() {
        NotificationCenter.default.addObserver(
            forName: .cloudKitNotificationReceived,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let ckNotification = notification.object as? CKNotification else { return }
            Task { @MainActor in
                self.handleNotification(ckNotification)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .cloudKitShareAccepted,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let metadata = notification.object as? CKShare.Metadata else { return }
            Task { @MainActor in
                self.handleShareAcceptance(shareMetadata: metadata)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Register for CloudKit subscription changes. Call on cold launch and when family/zone changes.
    func registerSubscriptions(for zoneID: CKRecordZone.ID, in database: CKDatabase) async {
        let subscription = CKDatabaseSubscription(subscriptionID: "lootlist-changes-\(zoneID.zoneName)")

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        do {
            _ = try await database.save(subscription)
            logger.info("CloudKit subscription registered for zone \(zoneID.zoneName, privacy: .public)")
        } catch {
            logger.error("Failed to register CloudKit subscription: \(error, privacy: .private)")
        }
    }

    /// Remove subscriptions (e.g., when family changes or user logs out).
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

    /// Handle an incoming silent push notification for CloudKit changes.
    func handleNotification(_ notification: CKNotification) {
        guard let databaseNotification = notification as? CKDatabaseNotification else { return }

        let recordTypeID = databaseNotification.subscriptionID ?? "unknown"
        logger.debug("CloudKit change notification received for record type: \(recordTypeID, privacy: .public)")

        for (_, continuation) in continuations {
            continuation.yield(.recordChanged(recordTypeID: recordTypeID))
        }
    }

    /// Handle a CKShare acceptance notification.
    func handleShareAcceptance(shareMetadata: CKShare.Metadata) {
        let shareID = shareMetadata.hierarchicalRootRecordID ?? shareMetadata.share.recordID
        logger.info("CKShare acceptance notification received for share: \(shareID.recordName, privacy: .public)")

        for (_, continuation) in continuations {
            continuation.yield(.shareAccepted(shareID: shareID))
        }
    }

    /// Subscribe to sync events. Returns an AsyncStream and a UUID for unsubscription.
    func subscribe() -> (stream: AsyncStream<SyncEvent>, id: UUID) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream()
        continuations[id] = continuation

        continuation.onTermination = { @Sendable [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.unsubscribe(id: id)
            }
        }

        return (stream, id)
    }

    /// Unsubscribe from sync events.
    func unsubscribe(id: UUID) {
        continuations[id]?.finish()
        continuations.removeValue(forKey: id)
    }

    /// Notify subscribers of a zone reset (e.g., after CloudKit schema migration).
    func notifyZoneReset() {
        for (_, continuation) in continuations {
            continuation.yield(.zoneReset)
        }
    }
}
