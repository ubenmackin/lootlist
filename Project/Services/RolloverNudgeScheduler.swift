//
//  RolloverNudgeScheduler.swift
//  LootList
//
//  Created by Ben Mackin on 9/26/26.
//

import Foundation
import UserNotifications

/// WHY single pending nudge: one payout-anchored reminder avoids badge stacking across foreground passes.
nonisolated enum RolloverNudgeScheduler {
    static let identifier = "com.volcrypt.lootlist.rollovernudge"
    private static let title = "New week is ready — open Loot List."
    private static let body = "Payouts plus quests rolled over. Open the app to settle the new week."

    static func scheduleWeeklyRolloverNudge(payoutDay: PayoutDay, now: Date) async {
        // WHY no prompt: the nudge rides existing permission so foreground sync never interrupts.
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        // WHY current calendar: fire components must match the device wall clock, not the UTC week math.
        let fireDate = WeekMath.scheduledRolloverDate(for: now, payoutDay: payoutDay)
        var calendar = Calendar.current
        calendar.timeZone = .current
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        components.timeZone = .current

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = NotificationEventType.rolloverNudge.rawValue
        content.userInfo = ["eventType": NotificationEventType.rolloverNudge.rawValue]

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        // WHY remove-before-add: rescheduling each foreground keeps exactly one pending request.
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        do {
            try await center.add(request)
        } catch {
            // WHY silent skip: a throttled center must not fail the foreground sync.
        }
    }

    static func cancelRolloverNudge() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
