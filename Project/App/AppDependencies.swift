//
//  AppDependencies.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Observation
import os
import SwiftData

@MainActor
@Observable
final class AppDependencies {
    static var shared: AppDependencies?

    let appState: AppState
    let cloudKitService: CloudKitService
    let familyService: FamilyService
    let xpService: XPService
    let questService: QuestService
    let treasuryService: TreasuryService
    let achievementService: AchievementService
    let avatarService: AvatarService
    let notificationService: NotificationService
    let spendingService: SpendingService
    let interestService: InterestService
    let ledgerImportService: LedgerImportService
    let appSyncCoordinator: AppSyncCoordinator
    let dataMigrationsCoordinator: DataMigrationsCoordinator
    let autoPayoutCoordinator: AutoPayoutCoordinator
    let cacheService: CacheService?
    let syncCoordinator: CKSyncEngineCoordinator
    let networkMonitor: NetworkMonitor
    let conflictResolver: CKSyncConflictResolver
    let syncEngineDelegateHandler: CKSyncEngineDelegateHandler
    let toastManager: ToastManager
    let celebrationManager: CelebrationManager
    let soundManager: SoundManager
    let gemService: GemService
    let lootDropService: LootDropService
    let dailyLoginService: DailyLoginService
    let bonusObjectiveService: BonusObjectiveService
    let equipmentService: EquipmentService
    let goalService: GoalService
    let bucketService: BucketService
    let matchService: MatchService
    let familyShareReconciler: FamilyShareReconciler
    let lifecycleCoordinator: AppLifecycleCoordinator

    init() {
        let app = AppState()
        let ck = CloudKitService()
        let isTest = TestEnvironment.isRunningUnitOrUITests
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "App")

        let cache = Self.makeCacheService(app: app, isTest: isTest, logger: logger)
        let toast = ToastManager()
        cache?.toastManager = toast
        let celebration = CelebrationManager()
        celebration.toastManager = toast
        let sound = SoundManager()

        let network = NetworkMonitor.shared
        network.start()
        networkMonitor = network

        // CacheService constructs its own background writer from the container
        // it created; every consumer below shares that single instance.
        let sharedBgActor = cache?.backgroundWriter
        app.backgroundCacheActor = sharedBgActor

        let syncStack = Self.makeSyncStack(
            ck: ck, cache: cache, app: app, toast: toast, backgroundCache: sharedBgActor
        )
        conflictResolver = syncStack.conflictResolver
        syncEngineDelegateHandler = syncStack.delegateHandler
        // Single shared coordinator instance handed to every downstream service.
        let syncCoord = syncStack.syncCoordinator
        syncCoordinator = syncCoord
        notificationService = syncStack.notificationService

        let xp = XPService(cloudKit: ck, notificationService: notificationService, cacheService: cache, toastManager: toast, appState: app, syncCoordinator: syncCoord)
        xp.celebrationManager = celebration
        let treasury = TreasuryService(cloudKit: ck, notificationService: notificationService, cacheService: cache, toastManager: toast, appState: app, syncCoordinator: syncCoord)
        let quest = QuestService(
            cloudKit: ck, xpService: xp, notificationService: notificationService,
            cacheService: cache, treasuryService: treasury, toastManager: toast,
            appState: app, syncCoordinator: syncCoord
        )
        let family = FamilyService(cloudKit: ck, appState: app, questService: quest, cacheService: cache, toastManager: toast, syncCoordinator: syncCoord)
        let reconciler = FamilyShareReconciler(familyService: family)
        if !isTest {
            reconciler.start()
        }

        let achievement = AchievementService(cloudKit: ck, cacheService: cache, toastManager: toast, appState: app, celebrationManager: celebration, syncCoordinator: syncCoord)
        achievement.notificationService = notificationService
        quest.achievementService = achievement
        let avatar = AvatarService(xp: xp)
        let manualSpending = SpendingService(cloudKit: ck, cacheService: cache, appState: app, syncCoordinator: syncCoord)
        manualSpending.toastManager = toast
        spendingService = manualSpending

        let interest = InterestService(cloudKit: ck, cacheService: cache, appState: app, syncCoordinator: syncCoord)
        let match = MatchService(cloudKit: ck, cacheService: cache, appState: app, syncCoordinator: syncCoord)
        let ledgerImport = LedgerImportService(cloudKit: ck, cacheService: cache, appState: app, syncCoordinator: syncCoord)
        let bucket = BucketService(cacheService: cache, syncCoordinator: syncCoord, appState: app)
        let goal = GoalService(
            cloudKit: ck, cacheService: cache, appState: app, syncCoordinator: syncCoord,
            achievementService: achievement, celebrationManager: celebration
        )

        let appSync = AppSyncCoordinator()
        app.cacheService = cache
        toastManager = toast

        let gamification = Self.makeGamificationServices(
            ck: ck, cache: cache, toast: toast, sound: sound, app: app, syncCoord: syncCoord, quest: quest
        )
        gemService = gamification.gem
        lootDropService = gamification.lootDrop
        dailyLoginService = gamification.dailyLogin
        bonusObjectiveService = gamification.bonusObjective
        equipmentService = gamification.equipment

        let migrations = Self.makeDataMigrations(cloudKit: ck, cache: cache, backgroundCache: sharedBgActor, syncCoordinator: syncCoord)

        if isTest {
            Self.seedTestData(app: app, cloudKit: ck, cache: cache, logger: logger)
        }

        let autoPayout = AutoPayoutCoordinator(
            treasuryService: treasury, questService: quest, familyService: family, appState: app
        )

        let lifecycle = AppLifecycleCoordinator(
            appState: app, cloudKitService: ck, syncCoordinator: syncCoord,
            appSyncCoordinator: appSync, dataMigrationsCoordinator: migrations,
            autoPayoutCoordinator: autoPayout
        )
        lifecycle.achievementService = achievement

        appState = app
        cloudKitService = ck
        familyService = family
        xpService = xp
        questService = quest
        treasuryService = treasury
        achievementService = achievement
        avatarService = avatar
        appSyncCoordinator = appSync
        dataMigrationsCoordinator = migrations
        autoPayoutCoordinator = autoPayout
        cacheService = cache
        celebrationManager = celebration
        soundManager = sound
        interestService = interest
        matchService = match
        ledgerImportService = ledgerImport
        goalService = goal
        bucketService = bucket
        familyShareReconciler = reconciler
        lifecycleCoordinator = lifecycle

        Self.shared = self
    }

    private struct SyncStack {
        let conflictResolver: CKSyncConflictResolver
        let delegateHandler: CKSyncEngineDelegateHandler
        let syncCoordinator: CKSyncEngineCoordinator
        let notificationService: NotificationService
    }

    private struct GamificationStack {
        let gem: GemService
        let lootDrop: LootDropService
        let dailyLogin: DailyLoginService
        let bonusObjective: BonusObjectiveService
        let equipment: EquipmentService
    }

    private static func makeSyncStack(
        ck: CloudKitService,
        cache: CacheService?,
        app: AppState,
        toast: ToastManager,
        backgroundCache: BackgroundCacheActor?
    ) -> SyncStack {
        let conflict = CKSyncConflictResolver(
            cacheService: cache, backgroundCache: backgroundCache,
            toastManager: toast, appState: app
        )
        let delegate = CKSyncEngineDelegateHandler(
            backgroundCache: backgroundCache, conflictResolver: conflict,
            cacheService: cache, appState: app
        )
        let syncCoord = CKSyncEngineCoordinator(
            cloudKitService: ck, delegateHandler: delegate, appState: app
        )
        let notification = NotificationService(
            cloudKit: ck, appState: app, cacheService: cache,
            toastManager: toast, syncCoordinator: syncCoord
        )
        delegate.setNotificationService(notification)
        return SyncStack(
            conflictResolver: conflict,
            delegateHandler: delegate,
            syncCoordinator: syncCoord,
            notificationService: notification
        )
    }

    private static func makeGamificationServices(
        ck: CloudKitService,
        cache: CacheService?,
        toast: ToastManager,
        sound: SoundManager,
        app: AppState,
        syncCoord: CKSyncEngineCoordinator,
        quest: QuestService
    ) -> GamificationStack {
        let gem = GemService(
            cloudKitService: ck, cacheService: cache, toastManager: toast,
            appState: app, syncCoordinator: syncCoord, soundManager: sound
        )
        let lootDrop = LootDropService(gemService: gem, toastManager: toast, soundManager: sound)
        quest.lootDropService = lootDrop
        let dailyLogin = DailyLoginService(cloudKitService: ck, cacheService: cache, appState: app, syncCoordinator: syncCoord)
        let bonusObjective = BonusObjectiveService(cloudKitService: ck, gemService: gem, soundManager: sound, cacheService: cache, appState: app, syncCoordinator: syncCoord)
        let equipment = EquipmentService(cloudKitService: ck, gemService: gem, soundManager: sound, cacheService: cache, appState: app, syncCoordinator: syncCoord)
        return GamificationStack(
            gem: gem,
            lootDrop: lootDrop,
            dailyLogin: dailyLogin,
            bonusObjective: bonusObjective,
            equipment: equipment
        )
    }

    private static func makeCacheService(app: AppState, isTest: Bool, logger: Logger) -> CacheService? {
        do {
            return try CacheService(inMemory: isTest)
        } catch {
            logger.error("Failed to initialize CacheService: \(error, privacy: .private)")
            if !isTest {
                app.cacheInitError = .cacheInitializationFailed(error.localizedDescription)
            }
            return nil
        }
    }

    private static func makeDataMigrations(
        cloudKit: CloudKitService,
        cache: CacheService?,
        backgroundCache: BackgroundCacheActor?,
        syncCoordinator: CKSyncEngineCoordinator? = nil
    ) -> DataMigrationsCoordinator {
        let migrations = DataMigrationsCoordinator()
        if let backgroundCache {
            migrations.register(DataMigrationsCoordinator.questTargetCountBackfillV2(backgroundCache: backgroundCache))
        }
        migrations.register(DataMigrationsCoordinator.heroNotificationPreferenceBackfillV1(cloudKit: cloudKit, cacheService: cache, syncCoordinator: syncCoordinator))
        migrations.register(DataMigrationsCoordinator.allowancePeriodSeedV1(cloudKit: cloudKit, cacheService: cache, syncCoordinator: syncCoordinator))
        return migrations
    }

    private static func seedTestData(
        app: AppState,
        cloudKit: CloudKitService,
        cache: CacheService?,
        logger: Logger
    ) {
        logger.info("Tests detected — seeding mock data and setting test auth state")
        // The hero-board scenario pre-claims board quests so both board
        // sections render deterministically; all other scenarios share the
        // standard seeded family.
        if TestEnvironment.activeScenario == .heroBoardWithClaims {
            SampleData.populate(cacheService: cache, boardClaims: 2)
        } else {
            SampleData.populate(cacheService: cache)
        }
        cloudKit.activeFamilyZoneID = SampleData.zoneID

        switch TestEnvironment.activeScenario {
        case .freshOnboarding:
            app.authStatus = .onboarding
        case .seededParent:
            cloudKit.activeIsOwner = true
            app.currentProfile = SampleData.parentProfile
            app.family = SampleData.family
            app.familyZoneID = SampleData.zoneID
            app.isZoneOwner = true
            app.authStatus = .authenticated
        case .seededChild, .heroBoardWithClaims, nil:
            cloudKit.activeIsOwner = false
            app.currentProfile = SampleData.heroProfile
            app.family = SampleData.family
            app.familyZoneID = SampleData.zoneID
            app.isZoneOwner = false
            app.authStatus = .authenticated
        }
    }
}
