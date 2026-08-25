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

enum NotificationServiceError: Error, LocalizedError, Equatable, Sendable {
    case centerFailure(String)
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .centerFailure: "Could not update notification settings. Please try again."
        case .persistenceFailed: "Could not save notification preferences. Please try again."
        }
    }
}

@MainActor
@Observable
final class NotificationService {
    static let verificationCategoryID = "questLog.verification"
    static let verificationApproveActionID = "questLog.verification.approve"
    static let verificationRejectActionID = "questLog.verification.reject"

    private let cloudKit: any CloudKitServiceProtocol
    private let appState: AppState

    var cacheService: CacheService?
    var syncCoordinator: CKSyncEngineCoordinator?

    var toastManager: ToastManager?

    private(set) var deviceToken: Data?
    private(set) var verificationCategoryRegistered = false

    var weeklySummaryProvider: (@Sendable (Profile, Family, Date) async -> String?)?

    private let defaults: UserDefaults

    init(cloudKit: any CloudKitServiceProtocol,
         appState: AppState,
         cacheService: CacheService? = nil,
         toastManager: ToastManager? = nil,
         syncCoordinator: CKSyncEngineCoordinator? = nil,
         defaults: UserDefaults = .standard)
    {
        self.cloudKit = cloudKit
        self.appState = appState
        self.cacheService = cacheService
        self.toastManager = toastManager
        self.syncCoordinator = syncCoordinator
        self.defaults = defaults
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
        // Trust the cached preference only after a completed sync pass for this
        // family's notification preferences. Before the
        // first sync — or after `clearAll()` — the UserDefaults mirror is the
        // source of truth for first-launch continuity.
        if let cached = cachedPreference(for: eventType),
           let familyName = appState.family?.id.recordName,
           cacheService?.isCacheFresh(familyRecordName: familyName, type: .notificationPreference) == true
        {
            return cached.enabled
        }
        return userDefaultsFallback(for: eventType)
    }

    func isNotificationEnabled(for eventType: NotificationEventType, profileRecordName: String?, familyRecordName: String?) -> Bool {
        guard let profileRecordName, let familyRecordName, let cacheService else {
            return isNotificationEnabled(for: eventType)
        }
        if let cached = cacheService.fetchNotificationPreference(
            profileRecordName: profileRecordName,
            familyRecordName: familyRecordName,
            eventType: eventType.rawValue
        ) {
            return cached.enabled
        }
        // Local device user fallback to UserDefaults
        if profileRecordName == appState.currentProfile?.id.recordName {
            return userDefaultsFallback(for: eventType)
        }
        // For peer profiles without a cached preference row, default to false (fail-closed)
        return false
    }

    private func cachedPreference(for eventType: NotificationEventType) -> NotificationPreferenceCache? {
        guard let cacheService,
              let profile = appState.currentProfile,
              let family = appState.family
        else { return nil }
        return cacheService.fetchNotificationPreference(
            profileRecordName: profile.id.recordName,
            familyRecordName: family.id.recordName,
            eventType: eventType.rawValue
        )
    }

    private func userDefaultsFallback(for eventType: NotificationEventType) -> Bool {
        let master = defaults.object(forKey: Self.masterDefaultsKey) as? Bool ?? false
        guard master else { return false }

        if let value = defaults.object(forKey: eventType.userDefaultsKey) as? Bool {
            return value
        }
        return false
    }

    private func mirrorToUserDefaults(event: NotificationEventType, enabled: Bool) {
        defaults.set(enabled, forKey: event.userDefaultsKey)
    }

    @discardableResult
    func updatePreference(event: NotificationEventType, enabled: Bool) async throws -> NotificationPreference {
        guard let profile = appState.currentProfile, let family = appState.family else {
            throw NotificationServiceError.persistenceFailed
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let zoneID = family.id.zoneID

        let deterministicRecordName = "pref-\(profile.id.recordName)-\(family.id.recordName)-\(event.rawValue)"
        let recordID = CKRecord.ID(recordName: deterministicRecordName, zoneID: zoneID)

        let preference = NotificationPreference(
            profile: profileRef,
            eventType: event,
            enabled: enabled,
            family: familyRef,
            id: recordID
        )

        cacheService?.upsertNotificationPreference(preference)
        mirrorToUserDefaults(event: event, enabled: enabled)

        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: preference.id, isOwner: isOwner)
        return preference
    }

    // MARK: - UserDefaults Keys

    static let masterDefaultsKey = "masterNotificationsEnabled"

    func send(_ eventType: NotificationEventType,
              to profile: Profile,
              title: String,
              body: String) async throws
    {
        let familyRecordName = profile.family.recordID.recordName
        guard isNotificationEnabled(for: eventType, profileRecordName: profile.id.recordName, familyRecordName: familyRecordName) else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [
            "eventType": eventType.rawValue,
            "profileID": profile.id.recordName
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: DesignSystemConstants.AnimationDuration.notificationTriggerInterval, repeats: false)
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

    func deliverSyncNotification(eventType: NotificationEventType,
                                 title: String,
                                 body: String,
                                 profileID: String) async throws
    {
        guard let currentProfile = appState.currentProfile,
              currentProfile.id.recordName != profileID
        else {
            // Skip self-notifications — the acting user already sees the result.
            return
        }
        let familyRecordName = appState.family?.id.recordName ?? currentProfile.family.recordID.recordName
        guard isNotificationEnabled(for: eventType, profileRecordName: currentProfile.id.recordName, familyRecordName: familyRecordName) else { return }

        // Deep-link payload carries authoring profileID for routing to relevant review/event screens.
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [
            "eventType": eventType.rawValue,
            "profileID": profileID
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: DesignSystemConstants.AnimationDuration.notificationTriggerInterval, repeats: false)
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
        guard isNotificationEnabled(for: .goldEarned, profileRecordName: profile.id.recordName, familyRecordName: family.id.recordName) else { return }

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
        guard isNotificationEnabled(
            for: .questNeedsReview,
            profileRecordName: parent.id.recordName,
            familyRecordName: parent.family.recordID.recordName
        ) else { return }

        await registerVerificationCategoryIfNeeded()

        let title = "⚔️ Quest Needs Review"
        let body = "A hero has completed a quest — tap to verify."

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

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: DesignSystemConstants.AnimationDuration.notificationTriggerInterval, repeats: false)
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

    func sendQuestRejected(questLog _: QuestCompletion, to hero: Profile) async throws {
        guard isNotificationEnabled(
            for: .questRejected,
            profileRecordName: hero.id.recordName,
            familyRecordName: hero.family.recordID.recordName
        ) else { return }

        let title = "❌ Quest Rejected"
        let body = "Your quest submission was not approved — check feedback and try again."

        try await send(.questRejected, to: hero, title: title, body: body)
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

    func updateAppBadgeCount(pendingCount: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(max(0, pendingCount))
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
        case .questRejected: "questRejectedNotificationsEnabled"
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
