//
//  NotificationService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData
import UIKit
import UserNotifications

enum NotificationServiceError: Error, Equatable, Sendable {
    case centerFailure(String)
    case persistenceFailed(String)
}

@MainActor
@Observable
final class NotificationService {
    static let verificationCategoryID = "questLog.verification"
    static let verificationApproveActionID = "questLog.verification.approve"
    static let verificationRejectActionID = "questLog.verification.reject"

    private let cloudKit: CloudKitService
    private let appState: AppState

    var cacheService: CacheService?

    private(set) var deviceToken: Data?
    private(set) var verificationCategoryRegistered = false

    var weeklySummaryProvider: (@Sendable (Profile, Family, Date) async -> String?)?

    init(cloudKit: CloudKitService,
         appState: AppState,
         cacheService: CacheService? = nil)
    {
        self.cloudKit = cloudKit
        self.appState = appState
        self.cacheService = cacheService
    }

    @discardableResult
    func requestAuthorization() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                registerForRemoteNotifications()
            }
            return granted
        } catch {
            throw NotificationServiceError.centerFailure("\(error)")
        }
    }

    @MainActor
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func handleDeviceToken(_ token: Data) {
        deviceToken = token
    }

    func isNotificationEnabled(for eventType: NotificationEventType) -> Bool {
        if let cached = cachedPreference(for: eventType) {
            return cached.enabled
        }
        return userDefaultsFallback(for: eventType)
    }

    private func cachedPreference(for eventType: NotificationEventType) -> NotificationPreferenceCache? {
        guard let cacheService,
              let profile = appState.currentProfile,
              let family = appState.family
        else { return nil }
        let profileName = profile.id.recordName
        let familyName = family.id.recordName
        let eventTypeRaw = eventType.rawValue
        let descriptor = FetchDescriptor<NotificationPreferenceCache>(
            predicate: #Predicate {
                $0.profileRecordName == profileName
                    && $0.familyRecordName == familyName
                    && $0.eventType == eventTypeRaw
            }
        )
        return try? cacheService.container.mainContext.fetch(descriptor).first
    }

    private func userDefaultsFallback(for eventType: NotificationEventType) -> Bool {
        let defaults = UserDefaults.standard
        let master = defaults.object(forKey: Self.masterDefaultsKey) as? Bool ?? true
        guard master else { return false }

        switch eventType {
        case .questAssigned:
            return defaults.object(forKey: "questAssignedNotificationsEnabled") as? Bool ?? true
        case .questNeedsReview:
            return defaults.object(forKey: "questNeedsReviewNotificationsEnabled") as? Bool ?? true
        case .questCompleted:
            return defaults.object(forKey: "questVerifiedNotificationsEnabled") as? Bool ?? true
        case .levelUp:
            return defaults.object(forKey: "levelUpNotificationsEnabled") as? Bool ?? true
        case .goldEarned:
            return defaults.object(forKey: "weeklySummaryNotificationsEnabled") as? Bool ?? true
        default:
            return true
        }
    }

    private func mirrorToUserDefaults(event: NotificationEventType, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: event.userDefaultsKey)
    }

    @discardableResult
    func updatePreference(event: NotificationEventType, enabled: Bool) async throws -> NotificationPreference {
        guard let profile = appState.currentProfile, let family = appState.family else {
            throw NotificationServiceError.persistenceFailed("No active profile/family for notification preference update")
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let zoneID = family.id.zoneID

        // Resolve the existing cached row once — used both to reuse the CK
        // record name (so CloudKit treats this as an update, not a create) and
        // as the pre-mutation snapshot for D2 rollback. A brand-new preference
        // (no prior cached row) gets a fresh UUID and falls back to
        // invalidate-on-failure.
        let snapshot = cachedPreference(for: event)
        let recordID = if let existingName = snapshot?.recordName {
            CKRecord.ID(recordName: existingName, zoneID: zoneID)
        } else {
            CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        }

        let preference = NotificationPreference(
            profile: profileRef,
            eventType: event,
            enabled: enabled,
            pushEnabled: enabled,
            family: familyRef,
            id: recordID
        )

        // Optimistic local write + UserDefaults mirror for fallback continuity.
        cacheService?.upsertNotificationPreference(preference)
        mirrorToUserDefaults(event: event, enabled: enabled)

        do {
            let saved = try await cloudKit.save(preference)
            cacheService?.upsertNotificationPreference(saved)
            return saved
        } catch {
            if let snapshot {
                // D2: UPDATE path — restore the pre-mutation cached value.
                cacheService?.upsertNotificationPreference(
                    snapshot.toNotificationPreference(zoneID: zoneID)
                )
            } else {
                // Brand-new preference with no prior cached row — invalidate.
                cacheService?.invalidateNotificationPreference(recordName: recordID.recordName)
            }
            throw error
        }
    }

    // MARK: - UserDefaults Keys

    static let masterDefaultsKey = "masterNotificationsEnabled"

    func send(_ eventType: NotificationEventType,
              to profile: Profile,
              title: String,
              body: String) async throws
    {
        guard isNotificationEnabled(for: eventType) else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [
            "eventType": eventType.rawValue,
            "profileID": profile.id.recordName
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "\(eventType.rawValue):\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        let center = UNUserNotificationCenter.current()
        do {
            try await center.add(request)
        } catch {
            throw NotificationServiceError.centerFailure("\(error)")
        }
    }

    func sendWeeklySummary(to profile: Profile,
                           family: Family,
                           weekOf: Date) async throws
    {
        guard isNotificationEnabled(for: .goldEarned) else { return }

        let title = "🎁 Sunday Loot Day"
        let body: String = if let provider = weeklySummaryProvider {
            await (provider(profile, family, weekOf)) ?? "Your weekly loot awaits!"
        } else {
            "Your weekly loot awaits!"
        }

        try await send(.goldEarned, to: profile, title: title, body: body)
    }

    func sendQuestNeedsReview(questLog: QuestCompletion,
                              to parent: Profile) async throws
    {
        guard isNotificationEnabled(for: .questNeedsReview) else { return }

        await registerVerificationCategoryIfNeeded()

        let title = "⚔️ Quest Needs Review"
        let body = "A hero has slain a quest — tap to verify."

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.verificationCategoryID
        content.userInfo = [
            "eventType": NotificationEventType.questNeedsReview.rawValue,
            "profileID": parent.id.recordName,
            "questLogID": questLog.id.recordName
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "questNeedsReview:\(questLog.id.recordName):\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        let center = UNUserNotificationCenter.current()
        do {
            try await center.add(request)
        } catch {
            throw NotificationServiceError.centerFailure("\(error)")
        }
    }

    func handleVerificationAction(_ action: String,
                                  questLogID: CKRecord.ID) async throws
        -> VerificationAction?
    {
        switch action {
        case Self.verificationApproveActionID:
            .approve(questLogID: questLogID)
        case Self.verificationRejectActionID:
            .reject(questLogID: questLogID)
        case UNNotificationDefaultActionIdentifier:
            .view(questLogID: questLogID)
        default:
            nil
        }
    }

    func registerVerificationCategoryIfNeeded() async {
        guard !verificationCategoryRegistered else { return }

        let approve = UNNotificationAction(
            identifier: Self.verificationApproveActionID,
            title: "Approve",
            options: [.foreground]
        )
        let reject = UNNotificationAction(
            identifier: Self.verificationRejectActionID,
            title: "Reject",
            options: [.foreground, .destructive]
        )

        let category = UNNotificationCategory(
            identifier: Self.verificationCategoryID,
            actions: [approve, reject],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        verificationCategoryRegistered = true
    }
}

enum VerificationAction: Sendable, Equatable {
    case approve(questLogID: CKRecord.ID)

    case reject(questLogID: CKRecord.ID)

    case view(questLogID: CKRecord.ID)
}

extension NotificationEventType {
    var userDefaultsKey: String {
        switch self {
        case .questAssigned: "questAssignedNotificationsEnabled"
        case .questNeedsReview: "questNeedsReviewNotificationsEnabled"
        case .questCompleted: "questVerifiedNotificationsEnabled"
        case .levelUp: "levelUpNotificationsEnabled"
        case .goldEarned: "weeklySummaryNotificationsEnabled"
        case .questMissed: "questMissedNotificationsEnabled"
        case .spendingLogged: "spendingLoggedNotificationsEnabled"
        case .trophyEarned: "trophyEarnedNotificationsEnabled"
        case .streakMilestone: "streakMilestoneNotificationsEnabled"
        }
    }
}
