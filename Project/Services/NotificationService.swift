import Foundation
import CloudKit
import UserNotifications
import UIKit

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

    private(set) var deviceToken: Data?

    private(set) var verificationCategoryRegistered = false

    var weeklySummaryProvider:
        ((Profile, Family, Date) async -> String?)?

    init(cloudKit: CloudKitService) {
        self.cloudKit = cloudKit
    }

    @discardableResult
    func requestAuthorization() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            throw NotificationServiceError.centerFailure("\(error)")
        }
    }

    @MainActor
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func handleDeviceToken(_ token: Data) {
        self.deviceToken = token
    }

    func fetchPreferences(profile: Profile) async throws
        -> [NotificationEventType: NotificationPreference] {

        let zoneID = Self.zoneID(for: profile)
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)

        let rows: [NotificationPreference]
        do {
            rows = try await cloudKit.query(
                NotificationPreference.self,
                predicate: NSPredicate(format: "profile == %@", profileRef),
                in: zoneID)
        } catch {
            throw NotificationServiceError.persistenceFailed("\(error)")
        }

        var byType: [NotificationEventType: NotificationPreference] = [:]
        for row in rows {
            byType[row.eventType] = row
        }
        return byType
    }

    func ensureDefaultPreferences(profile: Profile,
                                   role: UserRole,
                                   family: Family) async throws {
        let zoneID = Self.zoneID(for: profile)
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)

        let existing = try await fetchPreferences(profile: profile)

        for eventType in NotificationEventType.allCases {
            guard existing[eventType] == nil else { continue }

            let preference = NotificationPreference(
                profile: profileRef,
                eventType: eventType,
                role: role,
                family: familyRef)
            do {
                _ = try await cloudKit.save(preference, in: zoneID)
            } catch {
                throw NotificationServiceError.persistenceFailed("\(error)")
            }
        }
    }

    func setEnabled(_ enabled: Bool,
                     pushEnabled: Bool? = nil,
                     for eventType: NotificationEventType,
                     profile: Profile) async throws {

        let zoneID = Self.zoneID(for: profile)

        let existing = try await fetchPreferences(profile: profile)
        guard var preference = existing[eventType] else {
            throw NotificationServiceError.persistenceFailed(
                "No NotificationPreference for \(eventType.rawValue)")
        }

        preference.enabled = enabled
        if let pushEnabled {
            preference.pushEnabled = pushEnabled
        }

        do {
            _ = try await cloudKit.save(preference, in: zoneID)
        } catch {
            throw NotificationServiceError.persistenceFailed("\(error)")
        }
    }

    func send(_ eventType: NotificationEventType,
              to profile: Profile,
              title: String,
              body: String) async throws {

        let existing = try await fetchPreferences(profile: profile)
        guard let preference = existing[eventType], preference.enabled else {

            return
        }

        guard preference.pushEnabled else {

            Self.logInApp(eventType: eventType,
                           profile: profile,
                           title: title,
                           body: body)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [
            "eventType": eventType.rawValue,
            "profileID": profile.id.recordName,
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "\(eventType.rawValue):\(UUID().uuidString)",
            content: content,
            trigger: trigger)

        let center = UNUserNotificationCenter.current()
        do {
            try await center.add(request)
        } catch {
            throw NotificationServiceError.centerFailure("\(error)")
        }
    }

    func sendWeeklySummary(to profile: Profile,
                            family: Family,
                            weekOf: Date) async throws {

        let title = "🎁 Sunday Loot Day"
        let body: String
        if let provider = weeklySummaryProvider {
            body = (await provider(profile, family, weekOf))
                ?? "Your weekly loot awaits!"
        } else {
            body = "Your weekly loot awaits!"
        }

        try await send(.goldEarned, to: profile, title: title, body: body)
    }

    func sendQuestNeedsReview(questLog: QuestLog,
                                to parent: Profile) async throws {

        await registerVerificationCategoryIfNeeded()

        let title = "⚔️ Quest Needs Review"
        let body = "A hero has slain a quest — tap to verify."

        let existing = try await fetchPreferences(profile: parent)
        guard let preference = existing[.questNeedsReview],
              preference.enabled else {
            return
        }

        guard preference.pushEnabled else {
            Self.logInApp(eventType: .questNeedsReview,
                           profile: parent,
                           title: title,
                           body: body)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.verificationCategoryID
        content.userInfo = [
            "eventType": NotificationEventType.questNeedsReview.rawValue,
            "profileID": parent.id.recordName,
            "questLogID": questLog.id.recordName,
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "questNeedsReview:\(questLog.id.recordName):\(UUID().uuidString)",
            content: content,
            trigger: trigger)

        let center = UNUserNotificationCenter.current()
        do {
            try await center.add(request)
        } catch {
            throw NotificationServiceError.centerFailure("\(error)")
        }
    }

    func handleVerificationAction(_ action: String,
                                    questLogID: CKRecord.ID) async throws
        -> VerificationAction? {

        switch action {
        case Self.verificationApproveActionID:
            return .approve(questLogID: questLogID)
        case Self.verificationRejectActionID:
            return .reject(questLogID: questLogID)
        case UNNotificationDefaultActionIdentifier:

            return .view(questLogID: questLogID)
        default:

            return nil
        }
    }

    func registerVerificationCategoryIfNeeded() async {

        guard !verificationCategoryRegistered else { return }

        let approve = UNNotificationAction(
            identifier: Self.verificationApproveActionID,
            title: "Approve",
            options: [.foreground])
        let reject = UNNotificationAction(
            identifier: Self.verificationRejectActionID,
            title: "Reject",
            options: [.foreground, .destructive])

        let category = UNNotificationCategory(
            identifier: Self.verificationCategoryID,
            actions: [approve, reject],
            intentIdentifiers: [],
            options: [.customDismissAction])

        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        verificationCategoryRegistered = true
    }

    private static func zoneID(for profile: Profile) -> CKRecordZone.ID {

        CKRecordZone.ID(zoneName: profile.family.recordID.recordName,
                          ownerName: "__defaultOwner__")
    }

    private static func logInApp(eventType: NotificationEventType,
                                   profile: Profile,
                                   title: String,
                                   body: String) {

        #if DEBUG
        print("[QuestLog] in-app notification "
              + "(\(eventType.displayName) → \(profile.displayName)): "
              + "\(title) — \(body)")
        #endif
    }
}

enum VerificationAction: Sendable, Equatable {

    case approve(questLogID: CKRecord.ID)

    case reject(questLogID: CKRecord.ID)

    case view(questLogID: CKRecord.ID)
}
