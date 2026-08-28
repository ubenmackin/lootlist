//
//  NotificationRouter.swift
//  LootList
//
//  Created by Ben Mackin on 8/9/26.
//

import CloudKit
import Foundation
import os
import UserNotifications

/// Destination target for navigating from a tapped local notification.
enum NotificationRoute: Sendable, Equatable {
    /// Quest lifecycle banner (assigned / verified / rejected): show the
    /// viewer's quest surface.
    case quests

    /// "Quest needs review" banner: show the parent's pending-verification
    /// surface. `heroRecordName` is the completing hero (the authoring peer).
    case pendingVerifications(heroRecordName: String?)

    /// "Spending logged" banner: show the parent's view of the spender's
    /// ledger. `heroRecordName` is the spender (the authoring peer).
    case heroLedger(heroRecordName: String)
}

extension Notification.Name {
    static let notificationRouteTriggered = Notification.Name("notificationRouteTriggered")
}

/// Notification center delegate routing notification taps and actionable category responses.
@MainActor
final class NotificationRouter: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "NotificationRouter")

    /// Retained route for taps received before `AppDependencies` is ready,
    /// when posting to NotificationCenter would have no subscriber.
    private var pendingRoute: NotificationRoute?

    /// Hands the retained cold-start route to the first consumer and clears it.
    func takePendingRoute() -> NotificationRoute? {
        defer { pendingRoute = nil }
        return pendingRoute
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Present banners in the foreground so app-scheduled notifications stay
        // tappable instead of being swallowed while the app is open.
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let profileID = userInfo["profileID"] as? String

        let isVerificationAction = action == NotificationService.verificationApproveActionID
            || action == NotificationService.verificationRejectActionID

        if isVerificationAction, let questLogID = userInfo["questLogID"] as? String {
            performVerificationAction(action, questLogID: questLogID)
        } else if let eventType = (userInfo["eventType"] as? String)
            .flatMap(NotificationEventType.init(rawValue:))
        {
            route(eventType: eventType, profileID: profileID)
        } else {
            Self.logger.debug("Dropping notification tap with no recognizable payload")
        }

        completionHandler()
    }

    // MARK: - Routing

    /// Posts a resolved route to subscribers and retains it as a fallback for
    /// consumers that mount after the notification (cold start).
    private func deliver(_ route: NotificationRoute) {
        pendingRoute = route
        guard AppDependencies.shared != nil else { return }
        NotificationCenter.default.post(name: .notificationRouteTriggered, object: route)
    }

    /// Maps a decoded payload onto the tab that shows its content.
    private func route(eventType: NotificationEventType, profileID: String?) {
        guard let route = route(for: eventType, profileID: profileID) else {
            Self.logger.debug("No destination for \(eventType.rawValue, privacy: .private)")
            return
        }
        deliver(route)
    }

    private func route(for eventType: NotificationEventType, profileID: String?) -> NotificationRoute? {
        switch eventType {
        case .questNeedsReview:
            // A completion is awaiting review — surface the pending list with
            // the completing hero as context.
            return .pendingVerifications(heroRecordName: profileID)
        case .questAssigned, .questCompleted, .questRejected:
            // Quest lifecycle banners concern the viewer's own quest surface;
            // the authoring peer (creator / verifier) is not the destination.
            return .quests
        case .spendingLogged:
            // The spender owns the content — require the peer to route.
            guard let profileID else { return nil }
            return .heroLedger(heroRecordName: profileID)
        case .levelUp, .goldEarned, .questMissed, .trophyEarned, .streakMilestone:
            // Informational banners (weekly loot, progress) have no dedicated
            // destination beyond acknowledgment.
            return nil
        }
    }

    // MARK: - Quest Review Actions

    /// Executes inline verification actions from quest-review notification category.
    private func performVerificationAction(_ action: String, questLogID: String) {
        guard let deps = AppDependencies.shared else {
            // Dependencies are not built yet — the mutation cannot run, but the
            // tap should still land on the pending-review list after launch.
            pendingRoute = .pendingVerifications(heroRecordName: nil)
            return
        }

        Task {
            let zoneID = deps.appState.resolvedFamilyZoneID()
            let recordID = CKRecord.ID(recordName: questLogID, zoneID: zoneID)

            let verificationAction: VerificationAction
            do {
                guard let result = try await deps.notificationService
                    .handleVerificationAction(action, questLogID: recordID)
                else {
                    return
                }
                verificationAction = result
            } catch {
                Self.logger.error("Verification action '\(action, privacy: .private)' failed for quest log \(questLogID, privacy: .private): \(error, privacy: .private)")
                return
            }

            guard let parent = deps.appState.currentProfile, parent.role.isParent else {
                return
            }

            guard let familyName = deps.appState.family?.id.recordName,
                  let cachedLog = deps.cacheService.fetchQuestCompletion(recordName: questLogID, family: familyName)
            else {
                return
            }
            let questLog = cachedLog.toQuestCompletion(zoneID: zoneID)

            do {
                switch verificationAction {
                case .approve:
                    _ = try await deps.questService.verify(questLog: questLog, by: parent)
                case .reject:
                    _ = try await deps.questService.reject(questLog: questLog, by: parent)
                case .view:
                    deliver(.pendingVerifications(heroRecordName: nil))
                }
            } catch {
                deps.toastManager.show(
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    type: .error
                )
            }
        }
    }
}
