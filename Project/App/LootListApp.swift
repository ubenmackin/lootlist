//
//  LootListApp.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import os
import SwiftData
import SwiftUI

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
    let spendingService: any SpendingService
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
    let familyShareReconciler: FamilyShareReconciler
    let lifecycleCoordinator: AppLifecycleCoordinator

    init() {
        let app = AppState()
        let ck = CloudKitService()
        let isTest = TestEnvironment.isRunningUnitOrUITests
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "App")

        let cache = Self.makeCacheService(app: app, isTest: isTest, logger: logger)
        let toast = ToastManager()
        let celebration = CelebrationManager()
        celebration.toastManager = toast

        let network = NetworkMonitor.shared
        network.start()
        networkMonitor = network

        let conflict = CKSyncConflictResolver(cacheService: cache, toastManager: toast, appState: app)
        conflictResolver = conflict

        let sharedBgActor = cache.flatMap { $0.container.map { BackgroundCacheActor(container: $0) } }

        let delegate = CKSyncEngineDelegateHandler(
            backgroundCache: sharedBgActor,
            conflictResolver: conflict,
            cacheService: cache,
            appState: app
        )
        syncEngineDelegateHandler = delegate

        let syncCoord = CKSyncEngineCoordinator(
            cloudKitService: ck,
            delegateHandler: delegate,
            appState: app
        )
        syncCoordinator = syncCoord

        let notification = NotificationService(cloudKit: ck, appState: app, cacheService: cache, toastManager: toast, syncCoordinator: syncCoord)
        delegate.setNotificationService(notification)
        let xp = XPService(cloudKit: ck, notificationService: notification, cacheService: cache, toastManager: toast, appState: app, syncCoordinator: syncCoord)
        let treasury = TreasuryService(cloudKit: ck, notificationService: notification, cacheService: cache, toastManager: toast, appState: app, syncCoordinator: syncCoord)
        let quest = QuestService(
            cloudKit: ck,
            xpService: xp,
            notificationService: notification,
            cacheService: cache,
            treasuryService: treasury,
            toastManager: toast,
            appState: app,
            syncCoordinator: syncCoord
        )
        let family = FamilyService(cloudKit: ck, appState: app, questService: quest, cacheService: cache, toastManager: toast, syncCoordinator: syncCoord)
        let reconciler = FamilyShareReconciler(familyService: family)
        if !isTest {
            reconciler.start()
        }

        let achievement = AchievementService(cloudKit: ck, cacheService: cache, toastManager: toast, appState: app, celebrationManager: celebration, syncCoordinator: syncCoord)
        achievement.notificationService = notification
        quest.achievementService = achievement
        let avatar = AvatarService(xp: xp)
        let manualSpending = ManualSpendingService(cloudKit: ck, cacheService: cache, appState: app, syncCoordinator: syncCoord)
        manualSpending.toastManager = toast
        spendingService = manualSpending

        let appSync = AppSyncCoordinator()
        app.cacheService = cache
        toastManager = toast

        let migrations = Self.makeDataMigrations(cloudKit: ck, cache: cache, backgroundCache: sharedBgActor)

        if isTest {
            Self.seedTestData(app: app, cloudKit: ck, cache: cache, logger: logger)
        }

        let autoPayout = AutoPayoutCoordinator(
            treasuryService: treasury,
            questService: quest,
            familyService: family,
            appState: app
        )

        let lifecycle = AppLifecycleCoordinator(
            appState: app,
            cloudKitService: ck,
            syncCoordinator: syncCoord,
            appSyncCoordinator: appSync,
            dataMigrationsCoordinator: migrations,
            autoPayoutCoordinator: autoPayout
        )

        appState = app
        cloudKitService = ck
        familyService = family
        xpService = xp
        questService = quest
        treasuryService = treasury
        achievementService = achievement
        avatarService = avatar
        notificationService = notification
        appSyncCoordinator = appSync
        dataMigrationsCoordinator = migrations
        autoPayoutCoordinator = autoPayout
        cacheService = cache
        celebrationManager = celebration
        familyShareReconciler = reconciler
        lifecycleCoordinator = lifecycle

        Self.shared = self
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
        backgroundCache: BackgroundCacheActor?
    ) -> DataMigrationsCoordinator {
        let migrations = DataMigrationsCoordinator()
        migrations.register(DataMigrationsCoordinator.questNameBackfillV1(cloudKit: cloudKit))
        migrations.register(DataMigrationsCoordinator.questLedgerBackfillV1(cloudKit: cloudKit, cacheService: cache))
        migrations.register(DataMigrationsCoordinator.achievementMigrationV1(cloudKit: cloudKit, cacheService: cache))
        if let backgroundCache {
            migrations.register(DataMigrationsCoordinator.questTargetCountBackfillV2(backgroundCache: backgroundCache))
        }
        return migrations
    }

    private static func seedTestData(
        app: AppState,
        cloudKit: CloudKitService,
        cache: CacheService?,
        logger: Logger
    ) {
        logger.info("Tests detected — seeding mock data and setting test auth state")
        SampleData.populate(cloudKit: cloudKit, cacheService: cache)
        cloudKit.activeFamilyZoneID = SampleData.zoneID

        if CommandLine.arguments.contains("--onboarding") {
            app.authStatus = .onboarding
        } else if CommandLine.arguments.contains("--parent") {
            cloudKit.activeIsOwner = true
            app.currentProfile = SampleData.parentProfile
            app.family = SampleData.family
            app.familyZoneID = SampleData.zoneID
            app.isZoneOwner = true
            app.authStatus = .authenticated
        } else {
            cloudKit.activeIsOwner = false
            app.currentProfile = SampleData.heroProfile
            app.family = SampleData.family
            app.familyZoneID = SampleData.zoneID
            app.isZoneOwner = false
            app.authStatus = .authenticated
        }
    }
}

@main
struct LootListApp: App {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "Security")

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var dependencies = AppDependencies()

    private var appState: AppState {
        dependencies.appState
    }

    private var cloudKitService: CloudKitService {
        dependencies.cloudKitService
    }

    private var familyService: FamilyService {
        dependencies.familyService
    }

    private var xpService: XPService {
        dependencies.xpService
    }

    private var questService: QuestService {
        dependencies.questService
    }

    private var treasuryService: TreasuryService {
        dependencies.treasuryService
    }

    private var achievementService: AchievementService {
        dependencies.achievementService
    }

    private var avatarService: AvatarService {
        dependencies.avatarService
    }

    private var notificationService: NotificationService {
        dependencies.notificationService
    }

    private var appSyncCoordinator: AppSyncCoordinator {
        dependencies.appSyncCoordinator
    }

    private var dataMigrationsCoordinator: DataMigrationsCoordinator {
        dependencies.dataMigrationsCoordinator
    }

    private var cacheService: CacheService? {
        dependencies.cacheService
    }

    private var syncCoordinator: CKSyncEngineCoordinator {
        dependencies.syncCoordinator
    }

    private var networkMonitor: NetworkMonitor {
        dependencies.networkMonitor
    }

    private var toastManager: ToastManager {
        dependencies.toastManager
    }

    private var celebrationManager: CelebrationManager {
        dependencies.celebrationManager
    }

    var body: some Scene {
        WindowGroup {
            rootViewContent
        }
    }

    @ViewBuilder
    private var rootViewContent: some View {
        if let error = appState.cacheInitError {
            #if DEBUG
                let debugMessage: String = switch error {
                case let .cacheInitializationFailed(msg): msg
                }
                FatalCacheErrorView(message: debugMessage)
            #else
                FatalCacheErrorView()
            #endif
        } else {
            let baseRoot = RootView(pendingShareMetadata: pendingShareMetadata)
                .environment(appState)
                .environment(cloudKitService)
                .environment(familyService)
                .environment(xpService)
                .environment(questService)
                .environment(treasuryService)
                .environment(achievementService)
                .environment(avatarService)
                .environment(notificationService)
                .environment(appSyncCoordinator)
                .environment(cacheService)
                .environment(syncCoordinator)
                .environment(dependencies.lifecycleCoordinator)
                .environment(networkMonitor)
                .environment(toastManager)
                .environment(celebrationManager)
                .task {
                    if !TestEnvironment.isRunningUnitOrUITests {
                        await dependencies.lifecycleCoordinator.performInitialBootstrap()
                    }
                }
                .onOpenURL { url in
                    handleIncomingShareURL(url)
                }
                .task(id: appState.familyZoneID) {
                    guard appState.familyZoneID != nil, !TestEnvironment.isRunningUnitOrUITests else { return }
                    await dependencies.lifecycleCoordinator.performFamilyZoneChange()
                }
                .task(id: scenePhase) {
                    guard scenePhase == .active, !TestEnvironment.isRunningUnitOrUITests else { return }
                    await dependencies.lifecycleCoordinator.performForegroundSync()
                }
                // Toast banner overlay sits above all RootView states (splash,
                // onboarding, authenticated) so services can surface errors
                // universally. Hung on `baseRoot` so both branch consumers inherit it.
                .toastOverlay()
                // Celebration fullscreen overlay sits above the toast layer so
                // trophy unlocks and streak milestones take visual priority.
                .celebrationOverlay()

            if let container = cacheService?.container {
                baseRoot.modelContainer(container)
            } else {
                // Render `baseRoot` directly without a model container (test environment path).
                baseRoot
            }
        }
    }

    private func checkCloudKitAvailability() async {
        guard !TestEnvironment.isRunningUnitOrUITests else {
            logger.info("Tests detected — skipping CloudKit availability check")
            return
        }
        let container = CloudKitService.defaultContainer

        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                break
            case .noAccount, .restricted, .couldNotDetermine, .temporarilyUnavailable:
                logger.warning("CloudKit account status is \(String(describing: status))")
            @unknown default:
                break
            }
        } catch {
            logger.error("CloudKit availability check failed: \(error, privacy: .private)")
        }
    }

    private func handleIncomingShareURL(_ url: URL) {
        guard !TestEnvironment.isRunningUnitOrUITests else { return }
        logger.info("Handling incoming share URL: \(String(describing: url), privacy: .private)")
        let container = cloudKitService.container
        Task {
            do {
                let metadata = try await container.shareMetadata(for: url)
                let title = metadata.share[CKShare.SystemFieldKey.title] as? String ?? "nil"
                logger.info("Resolved share metadata for incoming share URL (title '\(title, privacy: .private)')")
                await MainActor.run {
                    pendingShareMetadata = metadata
                }
            } catch {
                logger.error("Share metadata fetch failed for incoming URL: \(error, privacy: .private)")
            }
        }
    }

    @State private var pendingShareMetadata: CKShare.Metadata?
}

private struct RootView: View {
    let pendingShareMetadata: CKShare.Metadata?

    @Environment(AppState.self) private var appState
    @Environment(CloudKitService.self) private var cloudKitService
    @Environment(FamilyService.self) private var familyService
    @Environment(CacheService.self) private var cacheService: CacheService?
    @Environment(CKSyncEngineCoordinator.self) private var syncCoordinator: CKSyncEngineCoordinator?
    @Environment(ToastManager.self) private var toastManager

    @State private var onboardingVM: OnboardingViewModel?
    @State private var spendingService: (any SpendingService)?

    var body: some View {
        Group {
            switch appState.authStatus {
            case .restoringSession:
                AppLaunchSplashScreen()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .checkingCloudData:
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Scanning iCloud for Guilds…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
            case let .detectedPreviousFamily(family, profile, zoneID, isOwner):
                DetectedFamilyView(
                    family: family,
                    profile: profile,
                    zoneID: zoneID,
                    isOwner: isOwner
                )
            case .onboarding:
                if let onboardingVM {
                    WelcomeView(viewModel: onboardingVM)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemBackground))
                }
            case .authenticated:
                if let spendingService {
                    TabBarView(spending: spendingService, familyRecordName: appState.family?.id.recordName)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemBackground))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemBackground))
                }
            case .offlineEmptyCache:
                VStack(spacing: 16) {
                    Image(systemName: "wifi.slash")
                        .font(.largeTitle)
                    Text("Offline & No Local Cache")
                        .font(.headline)
                    Text("Please connect to iCloud on first launch to load your Guild data.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
            }
        }
        .task(id: appState.authStatus) {
            switch appState.authStatus {
            case .onboarding:
                let vm = OnboardingViewModel(
                    familyService: familyService,
                    appState: appState
                )
                vm.pendingShareMetadata = pendingShareMetadata
                onboardingVM = vm
                spendingService = nil
            case .authenticated:
                onboardingVM = nil
                let spending = ManualSpendingService(cloudKit: cloudKitService, cacheService: cacheService, appState: appState, syncCoordinator: syncCoordinator)
                spending.toastManager = toastManager
                spendingService = spending
            case .restoringSession, .checkingCloudData, .detectedPreviousFamily, .offlineEmptyCache:
                onboardingVM = nil
            }
        }
        .onChange(of: pendingShareMetadata) { _, metadata in
            onboardingVM?.pendingShareMetadata = metadata
        }
    }
}
