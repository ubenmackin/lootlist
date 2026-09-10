//
//  NotificationRouter.swift
//  LootList
//
//  Created by Ben Mackin on 8/9/26.
//

import CloudKit
import Foundation
import os
import Synchronization
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

/// Routes notification taps and actionable category responses.
@MainActor
final class NotificationRouter: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    private static let logger = Logger(category: "NotificationRouter")

    /// Cold-start tap retention buffer.
    private let pendingRoute = Mutex<NotificationRoute?>(nil)

    // WHY: Explicit @MainActor annotation confirms compile-time isolation matching AppDependencies.shared;
    // UI callers (e.g. TabBarView) access synchronously on MainActor, while off-main callers must await.
    /// Process-wide accessor forwarding to the single owned container instance.
    @MainActor
    static var shared: NotificationRouter {
        if let owned = AppDependencies.shared?.notificationRouter {
            return owned
        }
        #if DEBUG
            if TestEnvironment.isRunningUnitOrUITests {
                logger.warning("NotificationRouter.shared accessed before container in tests; returning ephemeral with no retained route")
                return NotificationRouter()
            }
            // WHY trap-only-DEBUG: mis-wiring surfaces in development, Release stays launchable.
            preconditionFailure("NotificationRouter.shared requires AppDependencies")
        #else
            // WHY ephemeral-plus-fault: Release stays launchable while diagnostics capture mis-wiring.
            logger.fault("NotificationRouter.shared accessed before container; returning ephemeral with no retained route")
            return NotificationRouter()
        #endif
    }

    /// Hands the retained cold-start route to the first consumer and clears it.
    func takePendingRoute() -> NotificationRoute? {
        pendingRoute.withLock { route in
            defer { route = nil }
            return route
        }
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

    /// Posts a resolved route to subscribers and retains it for consumers
    /// that mount after the notification (cold start).
    private func deliver(_ route: NotificationRoute) {
        // WHY single path: retention covers late subscribers so posting with no observers stays harmless.
        pendingRoute.withLock { $0 = route }
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
        case .levelUp, .goldEarned, .questMissed, .trophyEarned, .streakMilestone, .spendDailyDigest:
            // Informational banners (weekly loot, progress, daily spend rollup) have no dedicated
            // destination beyond acknowledgment — the digest spans heroes, so no single ledger owns it.
            return nil
        }
    }

    // MARK: - Quest Review Actions

    /// Executes inline verification actions from quest-review notification category.
    private func performVerificationAction(_ action: String, questLogID: String) {
        guard let deps = AppDependencies.shared else {
            // WHY single path: mutation cannot run yet, but tap still lands on pending-review list after launch.
            deliver(.pendingVerifications(heroRecordName: nil))
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
