//
//  NotificationService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os
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

protocol WeeklySummaryProviding: Sendable {
    func summary(profile: Profile, family: Family, weekOf: Date) async -> String?
}

struct ProductionWeeklySummaryProvider: WeeklySummaryProviding, Sendable {
    func summary(profile _: Profile, family _: Family, weekOf _: Date) async -> String? {
        nil
    }
}

@MainActor
@Observable
final class NotificationService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "NotificationService")

    static let verificationCategoryID = "questLog.verification"
    static let verificationApproveActionID = "questLog.verification.approve"
    static let verificationRejectActionID = "questLog.verification.reject"

    private let cloudKit: any CloudKitServiceProtocol
    private let appState: AppState

    let cacheService: CacheService
    let syncCoordinator: CKSyncEngineCoordinator?
    let toastManager: ToastManager?

    private(set) var deviceToken: Data?
    private(set) var verificationCategoryRegistered = false
    private(set) var currentAppBadgeCount: Int = 0

    let weeklySummaryProvider: (any WeeklySummaryProviding)?

    private let defaults: UserDefaults

    init(cloudKit: any CloudKitServiceProtocol,
         appState: AppState,
         cacheService: CacheService,
         syncCoordinator: CKSyncEngineCoordinator? = nil,
         toastManager: ToastManager? = nil,
         weeklySummaryProvider: (any WeeklySummaryProviding)? = nil,
         defaults: UserDefaults = .standard)
    {
        self.cloudKit = cloudKit
        self.appState = appState
        self.cacheService = cacheService
        self.toastManager = toastManager
        self.syncCoordinator = syncCoordinator
        self.weeklySummaryProvider = weeklySummaryProvider
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

    // WHY: Bespoke UserDefaults fallback without CloudKit query/hydrate — intentionally inline, not a CacheFirst single-type flow.
    func isNotificationEnabled(for eventType: NotificationEventType) -> Bool {
        // Reads notification preference with cache freshness check.
        let scope: CKDatabase.Scope = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared
        if let cached = cachedPreference(for: eventType),
           let familyName = appState.family?.id.recordName,
           cacheService.isCacheAuthoritative(familyRecordName: familyName, type: .notificationPreference, scope: scope)
        {
            return cached.enabled
        }
        return userDefaultsFallback(for: eventType)
    }

    // WHY: Bespoke per-profile fallback to UserDefaults/peer default without CloudKit query — intentionally inline, not a CacheFirst flow.
    func isNotificationEnabled(for eventType: NotificationEventType, profileRecordName: String?, familyRecordName: String?) -> Bool {
        guard let profileRecordName, let familyRecordName else {
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
        guard let profile = appState.currentProfile,
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

    func setLocalFlag(event: NotificationEventType, enabled: Bool) {
        // Device-local mirror — authoritative record is NotificationPreference.
        defaults.set(enabled, forKey: event.userDefaultsKey)
        logger.debug("Notification local flag updated for \(event.rawValue): \(enabled)")
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

        await cacheService.upsertNotificationPreference(preference)
        mirrorToUserDefaults(event: event, enabled: enabled)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: preference.id, appState: appState, logger: logger, context: "NotificationService.updatePreference")
        return preference
    }

    // MARK: - UserDefaults Keys

    static let masterDefaultsKey = "masterNotificationsEnabled"
    static let clearBadgeOnLaunchDefaultsKey = "clearBadgeOnLaunch"

    func send(_ eventType: NotificationEventType,
              to profile: Profile,
              title: String,
              body: String,
              distinct: Bool = false) async throws
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
        let baseIdentifier = "\(eventType.rawValue):\(profile.id.recordName)"
        let identifier = distinct ? "\(baseIdentifier):\(UUID().uuidString)" : baseIdentifier
        let request = UNNotificationRequest(
            identifier: identifier,
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
                                 profileID: String,
                                 distinct: Bool = false) async throws
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
        let baseIdentifier = "\(eventType.rawValue):\(profileID)"
        let identifier = distinct ? "\(baseIdentifier):\(UUID().uuidString)" : baseIdentifier
        let request = UNNotificationRequest(
            identifier: identifier,
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

        let title = "🎁 Allowance Day"
        let body: String = if let provider = weeklySummaryProvider {
            await provider.summary(profile: profile, family: family, weekOf: weekOf) ?? "Your weekly allowance is ready!"
        } else {
            "Your weekly allowance is ready!"
        }

        try await send(.goldEarned, to: profile, title: title, body: body)
    }

    func sendQuestNeedsReview(questLog: QuestCompletion,
                              to parent: Profile,
                              distinct: Bool = false) async throws
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
        let baseIdentifier = "\(NotificationEventType.questNeedsReview.rawValue):\(parent.id.recordName):\(questLog.id.recordName)"
        let identifier = distinct ? "\(baseIdentifier):\(UUID().uuidString)" : baseIdentifier
        let request = UNNotificationRequest(
            identifier: identifier,
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

    func removePendingNotificationRequests(withIdentifier identifier: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
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

    func updateAppBadgeCount(pendingCount: Int, role: UserRole? = nil) async {
        let isParent = role?.isParent ?? appState.currentProfile?.role.isParent ?? false
        guard isParent else {
            await clearAppBadge()
            return
        }

        let clearOnLaunch = defaults.bool(forKey: Self.clearBadgeOnLaunchDefaultsKey)
        let targetCount = clearOnLaunch ? 0 : max(0, pendingCount)
        currentAppBadgeCount = targetCount
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(targetCount)
        } catch {
            logger.warning("Failed to update app badge count to \(targetCount): \(error, privacy: .private)")
        }
    }

    func clearAppBadge() async {
        currentAppBadgeCount = 0
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(0)
        } catch {
            logger.warning("Failed to clear app badge count: \(error, privacy: .private)")
        }
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
