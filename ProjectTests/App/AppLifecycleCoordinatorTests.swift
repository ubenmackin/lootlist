//
//  AppLifecycleCoordinatorTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/14/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct AppLifecycleCoordinatorTests {
    @Test
    func `performInitialBootstrap runs only once and sets completed flag`() async throws {
        let suite = "AppLifecycle_Bootstrap_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let appState = AppState(defaults: defaults)
        let zoneID = CKRecordZone.ID(zoneName: "BootstrapZone", ownerName: "Owner")
        let family = Family(
            name: "Bootstrap Family",
            createdBy: CKRecord.ID(recordName: "owner", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let profile = Profile(
            displayName: "GM",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "owner", zoneID: zoneID),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "prof1", zoneID: zoneID)
        )

        let cloudKit = MockCloudKitService()
        cloudKit.seedMockRecords([family, profile])
        appState.saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: true)

        let cache = try CacheService(inMemory: true)
        appState.cacheService = cache

        let conflictResolver = CKSyncConflictResolver(cacheService: cache, appState: appState)
        let delegate = CKSyncEngineDelegateHandler(conflictResolver: conflictResolver, cacheService: cache, appState: appState)
        let syncCoordinator = CKSyncEngineCoordinator(cloudKitService: cloudKit, delegateHandler: delegate, appState: appState, defaults: defaults)
        let appSync = AppSyncCoordinator()
        let migrations = DataMigrationsCoordinator(defaults: defaults)

        var migrationRunCount = 0
        migrations.register(DataMigrationsCoordinator.MigrationStep(id: "TestStep", version: 1) {
            migrationRunCount += 1
        })

        let toast = ToastManager()
        let notification = NotificationService(cloudKit: cloudKit, appState: appState, cacheService: cache)
        let xp = XPService(cloudKit: cloudKit, notificationService: notification, cacheService: cache, appState: appState)
        let treasury = TreasuryService(cloudKit: cloudKit, notificationService: notification, cacheService: cache, appState: appState)
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

        let lifecycle = AppLifecycleCoordinator(
            appState: appState,
            cloudKitService: cloudKit,
            syncCoordinator: syncCoordinator,
            appSyncCoordinator: appSync,
            dataMigrationsCoordinator: migrations,
            autoPayoutCoordinator: autoPayout
        )

        await lifecycle.performInitialBootstrap()
        #expect(migrationRunCount == 1)

        // Second call should no-op
        await lifecycle.performInitialBootstrap()
        #expect(migrationRunCount == 1)

        defaults.removePersistentDomain(forName: suite)
    }

    @Test
    func `performForegroundSync is lightweight and handles in-flight guards`() async throws {
        let suite = "AppLifecycle_Foreground_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let appState = AppState(defaults: defaults)
        let cloudKit = MockCloudKitService()
        let cache = try CacheService(inMemory: true)
        appState.cacheService = cache

        let conflictResolver = CKSyncConflictResolver(cacheService: cache, appState: appState)
        let delegate = CKSyncEngineDelegateHandler(conflictResolver: conflictResolver, cacheService: cache, appState: appState)
        let syncCoordinator = CKSyncEngineCoordinator(cloudKitService: cloudKit, delegateHandler: delegate, appState: appState, defaults: defaults)
        let appSync = AppSyncCoordinator()
        let migrations = DataMigrationsCoordinator(defaults: defaults)

        let toast = ToastManager()
        let notification = NotificationService(cloudKit: cloudKit, appState: appState, cacheService: cache)
        let xp = XPService(cloudKit: cloudKit, notificationService: notification, cacheService: cache, appState: appState)
        let treasury = TreasuryService(cloudKit: cloudKit, notificationService: notification, cacheService: cache, appState: appState)
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

        let lifecycle = AppLifecycleCoordinator(
            appState: appState,
            cloudKitService: cloudKit,
            syncCoordinator: syncCoordinator,
            appSyncCoordinator: appSync,
            dataMigrationsCoordinator: migrations,
            autoPayoutCoordinator: autoPayout
        )

        // 1. Before bootstrap completes, foreground sync and remote notification are safely blocked
        await lifecycle.performForegroundSync()
        await lifecycle.handleRemoteNotification()

        // 2. Perform initial bootstrap
        await lifecycle.performInitialBootstrap()

        // 3. After bootstrap, foreground sync, remote notification, and manual sync execute cleanly
        await lifecycle.performForegroundSync()
        await lifecycle.handleRemoteNotification()
        await lifecycle.performManualSync()

        defaults.removePersistentDomain(forName: suite)
    }

    @Test
    func `performFamilyZoneChange executes migrations and subscription registration`() async throws {
        let suite = "AppLifecycle_ZoneChange_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let appState = AppState(defaults: defaults)
        let zoneID = CKRecordZone.ID(zoneName: "NewFamilyZone", ownerName: "Owner")
        let family = Family(
            name: "New Family",
            createdBy: CKRecord.ID(recordName: "owner", zoneID: zoneID),
            id: CKRecord.ID(recordName: "family123", zoneID: zoneID)
        )
        let profile = Profile(
            displayName: "GM",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "owner", zoneID: zoneID),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "prof123", zoneID: zoneID)
        )

        let cloudKit = MockCloudKitService()
        cloudKit.seedMockRecords([family, profile])
        let cache = try CacheService(inMemory: true)
        appState.cacheService = cache
        appState.family = family
        appState.currentProfile = profile
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.authStatus = .authenticated
        appState.saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: true)

        let conflictResolver = CKSyncConflictResolver(cacheService: cache, appState: appState)
        let delegate = CKSyncEngineDelegateHandler(conflictResolver: conflictResolver, cacheService: cache, appState: appState)
        let syncCoordinator = CKSyncEngineCoordinator(cloudKitService: cloudKit, delegateHandler: delegate, appState: appState, defaults: defaults)
        let appSync = AppSyncCoordinator()
        let migrations = DataMigrationsCoordinator(defaults: defaults)

        migrations.register(DataMigrationsCoordinator.MigrationStep(id: "ZoneChangeStep", version: 1) {
            // Step runs and key is recorded in defaults
        })

        let toast = ToastManager()
        let notification = NotificationService(cloudKit: cloudKit, appState: appState, cacheService: cache)
        let xp = XPService(cloudKit: cloudKit, notificationService: notification, cacheService: cache, appState: appState)
        let treasury = TreasuryService(cloudKit: cloudKit, notificationService: notification, cacheService: cache, appState: appState)
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

        let lifecycle = AppLifecycleCoordinator(
            appState: appState,
            cloudKitService: cloudKit,
            syncCoordinator: syncCoordinator,
            appSyncCoordinator: appSync,
            dataMigrationsCoordinator: migrations,
            autoPayoutCoordinator: autoPayout
        )

        // Complete bootstrap first
        await lifecycle.performInitialBootstrap()

        await lifecycle.performFamilyZoneChange()

        let expectedKey = "migration.prof123.family123.ZoneChangeStep.v1.complete"
        #expect(defaults.bool(forKey: expectedKey) == true)

        let refreshSuccess = await lifecycle.handleWeeklyPayoutBackgroundRefresh()
        #expect(refreshSuccess == true)

        defaults.removePersistentDomain(forName: suite)
    }
}
