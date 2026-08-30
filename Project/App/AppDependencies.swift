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
    /// Cold-start singleton — set once in init; read is MainActor-isolated. Prefer injecting AppDependencies via Environment rather than reaching for shared.
    private(set) static var shared: AppDependencies?

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
    let cacheService: CacheService
    let syncCoordinator: CKSyncEngineCoordinator
    let networkMonitor: NetworkMonitor
    /// Protocol-typed reachability for injected consumers; debug overlay and lifecycle debounce continue to use the concrete monitor.
    var networkMonitoring: any NetworkMonitoring {
        networkMonitor
    }

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
    let heroBoardService: HeroBoardService
    let familyDiscoveryService: FamilyDiscoveryService

    init() {
        let foundations = Self.makeFoundations()
        let syncStack = Self.makeSyncStack(
            ck: foundations.cloudKit,
            cache: foundations.cache,
            app: foundations.app,
            toast: foundations.toast,
            backgroundCache: foundations.sharedBgActor
        )
        Self.attachWriterIfNeeded(foundations: foundations, syncStack: syncStack)
        let core = Self.makeCoreServices(foundations: foundations, syncStack: syncStack)
        let gamification = Self.makeGamificationServices(
            ck: foundations.cloudKit,
            cache: foundations.cache,
            toast: foundations.toast,
            sound: foundations.sound,
            app: foundations.app,
            syncCoord: syncStack.syncCoordinator,
            quest: core.quest
        )
        let migrations = Self.makeDataMigrations(
            cloudKit: foundations.cloudKit,
            cache: foundations.cache,
            backgroundCache: foundations.sharedBgActor,
            syncCoordinator: syncStack.syncCoordinator
        )
        if foundations.isTest {
            Self.seedTestData(
                app: foundations.app,
                cloudKit: foundations.cloudKit,
                cache: foundations.cache,
                logger: foundations.logger
            )
        }
        let autoPayout = AutoPayoutCoordinator(
            treasuryService: core.treasury,
            questService: core.quest,
            familyService: core.family,
            appState: foundations.app
        )
        let lifecycle = AppLifecycleCoordinator(
            appState: foundations.app,
            cloudKitService: foundations.cloudKit,
            syncCoordinator: syncStack.syncCoordinator,
            appSyncCoordinator: core.appSync,
            dataMigrationsCoordinator: migrations,
            autoPayoutCoordinator: autoPayout
        )
        lifecycle.achievementService = core.achievement

        // Inject discovery service so AppState stays a thin session holder.
        let discoveryService = FamilyDiscoveryService()
        foundations.app.discoveryService = discoveryService

        appState = foundations.app
        cloudKitService = foundations.cloudKit
        cacheService = foundations.cache
        networkMonitor = foundations.network
        toastManager = foundations.toast
        celebrationManager = foundations.celebration
        soundManager = foundations.sound
        conflictResolver = syncStack.conflictResolver
        syncEngineDelegateHandler = syncStack.delegateHandler
        syncCoordinator = syncStack.syncCoordinator
        notificationService = syncStack.notificationService
        familyService = core.family
        xpService = core.xp
        questService = core.quest
        treasuryService = core.treasury
        achievementService = core.achievement
        avatarService = core.avatar
        spendingService = core.spending
        interestService = core.interest
        matchService = core.match
        ledgerImportService = core.ledgerImport
        bucketService = core.bucket
        goalService = core.goal
        heroBoardService = core.heroBoard
        appSyncCoordinator = core.appSync
        dataMigrationsCoordinator = migrations
        autoPayoutCoordinator = autoPayout
        lifecycleCoordinator = lifecycle
        familyShareReconciler = core.reconciler
        gemService = gamification.gem
        lootDropService = gamification.lootDrop
        dailyLoginService = gamification.dailyLogin
        bonusObjectiveService = gamification.bonusObjective
        equipmentService = gamification.equipment
        familyDiscoveryService = discoveryService

        Self.shared = self
    }

    private struct Foundations {
        let app: AppState
        let cloudKit: CloudKitService
        let cache: CacheService
        let toast: ToastManager
        let celebration: CelebrationManager
        let sound: SoundManager
        let network: NetworkMonitor
        let logger: Logger
        let isTest: Bool
        let sharedBgActor: BackgroundCacheActor?
    }

    private struct CoreServices {
        let xp: XPService
        let treasury: TreasuryService
        let quest: QuestService
        let family: FamilyService
        let reconciler: FamilyShareReconciler
        let achievement: AchievementService
        let avatar: AvatarService
        let spending: SpendingService
        let interest: InterestService
        let match: MatchService
        let ledgerImport: LedgerImportService
        let bucket: BucketService
        let goal: GoalService
        let heroBoard: HeroBoardService
        let appSync: AppSyncCoordinator
    }

    private static func makeFoundations() -> Foundations {
        let app = AppState()
        let ck = CloudKitService()
        let isTest = TestEnvironment.isRunningUnitOrUITests
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "App")
        let cache = makeCacheService(app: app, isTest: isTest, logger: logger)
        let toast = ToastManager()
        cache.toastManager = toast
        let celebration = CelebrationManager()
        celebration.toastManager = toast
        let sound = SoundManager()
        let network = NetworkMonitor()
        network.start()
        let sharedBgActor = cache.backgroundWriter
        app.backgroundCacheActor = sharedBgActor
        return Foundations(
            app: app,
            cloudKit: ck,
            cache: cache,
            toast: toast,
            celebration: celebration,
            sound: sound,
            network: network,
            logger: logger,
            isTest: isTest,
            sharedBgActor: sharedBgActor
        )
    }

    private static func attachWriterIfNeeded(foundations: Foundations, syncStack: SyncStack) {
        let cache = foundations.cache
        let app = foundations.app
        let isTest = foundations.isTest
        let sharedBgActor = foundations.sharedBgActor
        if !isTest, cache.container != nil {
            if let sharedBgActor {
                syncStack.delegateHandler.setBackgroundCache(sharedBgActor)
                syncStack.conflictResolver.setBackgroundCache(sharedBgActor)
            } else {
                let handler = syncStack.delegateHandler
                let resolver = syncStack.conflictResolver
                Task { [weak cache, weak app, weak handler, weak resolver] in
                    await cache?.bootstrapBackgroundWriterIfNeeded()
                    guard let writer = cache?.backgroundWriter else { return }
                    if app?.backgroundCacheActor == nil {
                        app?.backgroundCacheActor = writer
                    }
                    handler?.setBackgroundCache(writer)
                    resolver?.setBackgroundCache(writer)
                }
            }
        } else if let sharedBgActor {
            syncStack.delegateHandler.setBackgroundCache(sharedBgActor)
            syncStack.conflictResolver.setBackgroundCache(sharedBgActor)
        }
    }

    private static func makeCoreServices(foundations: Foundations, syncStack: SyncStack) -> CoreServices {
        let ck = foundations.cloudKit
        let cache = foundations.cache
        let app = foundations.app
        let toast = foundations.toast
        let celebration = foundations.celebration
        let syncCoord = syncStack.syncCoordinator
        let notificationService = syncStack.notificationService

        let xp = XPService(
            cloudKit: ck,
            notificationService: notificationService,
            cacheService: cache,
            toastManager: toast,
            appState: app,
            syncCoordinator: syncCoord
        )
        xp.celebrationManager = celebration
        let treasury = TreasuryService(
            cloudKit: ck,
            notificationService: notificationService,
            cacheService: cache,
            toastManager: toast,
            appState: app,
            syncCoordinator: syncCoord
        )
        let quest = QuestService(
            cloudKit: ck,
            xpService: xp,
            notificationService: notificationService,
            cacheService: cache,
            treasuryService: treasury,
            toastManager: toast,
            appState: app,
            syncCoordinator: syncCoord
        )
        let family = FamilyService(
            cloudKit: ck,
            appState: app,
            questService: quest,
            cacheService: cache,
            toastManager: toast,
            syncCoordinator: syncCoord
        )
        let reconciler = FamilyShareReconciler(familyService: family)
        if !foundations.isTest {
            reconciler.start()
        }
        let achievement = AchievementService(
            cloudKit: ck,
            cacheService: cache,
            toastManager: toast,
            appState: app,
            celebrationManager: celebration,
            syncCoordinator: syncCoord
        )
        achievement.notificationService = notificationService
        quest.achievementService = achievement
        let avatar = AvatarService(xp: xp)
        let manualSpending = SpendingService(cloudKit: ck, cacheService: cache, appState: app, syncCoordinator: syncCoord)
        manualSpending.toastManager = toast
        let interest = InterestService(cloudKit: ck, cacheService: cache, appState: app, syncCoordinator: syncCoord)
        let match = MatchService(cloudKit: ck, cacheService: cache, appState: app, syncCoordinator: syncCoord)
        let ledgerImport = LedgerImportService(cloudKit: ck, cacheService: cache, appState: app, syncCoordinator: syncCoord)
        let bucket = BucketService(cacheService: cache, syncCoordinator: syncCoord, appState: app)
        let goal = GoalService(
            cloudKit: ck,
            cacheService: cache,
            appState: app,
            syncCoordinator: syncCoord,
            achievementService: achievement,
            celebrationManager: celebration
        )
        let heroBoard = HeroBoardService(questService: quest, cacheService: cache, syncCoordinator: syncCoord, appState: app)
        let appSync = AppSyncCoordinator()
        app.cacheService = cache
        return CoreServices(
            xp: xp,
            treasury: treasury,
            quest: quest,
            family: family,
            reconciler: reconciler,
            achievement: achievement,
            avatar: avatar,
            spending: manualSpending,
            interest: interest,
            match: match,
            ledgerImport: ledgerImport,
            bucket: bucket,
            goal: goal,
            heroBoard: heroBoard,
            appSync: appSync
        )
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
        cache: CacheService,
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
        cache: CacheService,
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

    private static func makeCacheService(app: AppState, isTest: Bool, logger: Logger) -> CacheService {
        do {
            return try CacheService(inMemory: isTest)
        } catch {
            logger.error("Failed to initialize CacheService: \(error, privacy: .private)")
            if !isTest {
                app.cacheInitError = .cacheInitializationFailed(error.localizedDescription)
            }
            return CacheService.inMemoryFallback(logger: logger)
        }
    }

    private static func makeDataMigrations(
        cloudKit: CloudKitService,
        cache: CacheService,
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
        cache: CacheService,
        logger: Logger
    ) {
        logger.info("Tests detected — seeding mock data and setting test auth state")
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
