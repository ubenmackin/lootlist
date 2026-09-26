//
//  RolloverNudgeSchedulerTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/26/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing
import UserNotifications

@MainActor
private final class RolloverNudgeStubSync: SyncCoordinating {
    func fetchChanges() async {}
    func sendPendingChanges() async {}
}

@MainActor
struct RolloverNudgeSchedulerTests {
    private func makeLifecycle(appState: AppState, cloudKit: MockCloudKitService, defaults: UserDefaults) throws -> AppLifecycleCoordinator {
        let cache = try CacheService(inMemory: true, defaults: defaults)
        appState.cacheService = cache
        if let container = cache.container {
            appState.backgroundCacheActor = BackgroundCacheActor(container: container)
        }
        let notification = NotificationService(cloudKit: cloudKit, appState: appState, cacheService: cache, defaults: defaults)
        let xp = XPService(cloudKit: cloudKit, notificationService: notification, cacheService: cache, appState: appState)
        let treasury = TreasuryService(cloudKit: cloudKit, notificationService: notification, cacheService: cache, appState: appState)
        let toast = ToastManager()
        let quest = QuestService(
            cloudKit: cloudKit,
            xpService: xp,
            notificationService: notification,
            cacheService: cache,
            treasuryService: treasury,
            toastManager: toast,
            appState: appState
        )
        let familyService = FamilyService(cloudKit: cloudKit, appState: appState, questService: quest, cacheService: cache)
        let autoPayout = AutoPayoutCoordinator(
            treasuryService: treasury,
            questService: quest,
            familyService: familyService,
            appState: appState,
            toastManager: toast
        )
        return AppLifecycleCoordinator(
            appState: appState,
            cloudKitService: cloudKit,
            syncCoordinator: RolloverNudgeStubSync(),
            appSyncCoordinator: AppSyncCoordinator(),
            dataMigrationsCoordinator: DataMigrationsCoordinator(defaults: defaults),
            autoPayoutCoordinator: autoPayout
        )
    }

    @Test
    func `identifier matches production contract verbatim`() {
        #expect(RolloverNudgeScheduler.identifier == "com.volcrypt.lootlist.rollovernudge")
    }

    @Test
    func `trigger date equals scheduled rollover date for Sunday and Wednesday payout days`() throws {
        let cal = Calendar.iso8601UTC
        let sundayNoon = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 12, minute: 0)))
        let sundayFireDate = WeekMath.scheduledRolloverDate(for: sundayNoon, payoutDay: .sunday)
        let expectedSunday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 10)))
        #expect(sundayFireDate == expectedSunday)

        let wednesdayFireDate = WeekMath.scheduledRolloverDate(for: sundayNoon, payoutDay: .wednesday)
        let wednesdayStart = WeekMath.startOfWeek(for: sundayNoon, payoutDay: .wednesday)
        #expect(wednesdayFireDate == WeekMath.weekRange(starting: wednesdayStart).upperBound)
        #expect(wednesdayFireDate != sundayFireDate)

        // WHY wall-clock round-trip: the scheduler derives trigger components from this date.
        var calendar = Calendar.current
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wednesdayFireDate)
        components.timeZone = .current
        let rebuilt = calendar.date(from: components)
        #expect(abs((rebuilt ?? .distantPast).timeIntervalSince(wednesdayFireDate)) < 1)
    }

    @Test
    func `hero profile takes parent-only cancel path`() async throws {
        // WHY skip without iCloud: notification-center calls hang with no account.
        guard await TestNotificationGate.iCloudAccountAvailable() else {
            print("SKIPPED: no iCloud account on simulator (notification center would hang)")
            return
        }
        let defaults = UserDefaults.ephemeral()
        let zoneID = ExhaustiveCacheFixtures.sharedZoneID
        let cloudKit = MockCloudKitService()
        let appState = AppState(defaults: defaults)
        var family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID)
        family.payoutDay = .wednesday
        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID)
        appState.family = family
        appState.currentProfile = hero
        #expect(hero.role.isParent == false)

        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, defaults: defaults)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [RolloverNudgeScheduler.identifier])
        await lifecycle.scheduleRolloverNudgeIfParent(now: Date())

        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        #expect(!pending.contains(where: { $0.identifier == RolloverNudgeScheduler.identifier }))
    }

    @Test
    func `denied permission schedules nothing`() async {
        guard await TestNotificationGate.iCloudAccountAvailable() else {
            print("SKIPPED: no iCloud account on simulator (notification center would hang)")
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus != .authorized else {
            print("SKIPPED: notifications authorized, denied path not observable")
            return
        }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [RolloverNudgeScheduler.identifier])
        await RolloverNudgeScheduler.scheduleWeeklyRolloverNudge(payoutDay: .wednesday, now: Date())
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        #expect(!pending.contains(where: { $0.identifier == RolloverNudgeScheduler.identifier }))
    }
}
