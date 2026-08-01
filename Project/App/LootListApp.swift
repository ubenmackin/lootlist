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
    let appState: AppState
    let cloudKitService: CloudKitService
    let familyService: FamilyService
    let xpService: XPService
    let questService: QuestService
    let treasuryService: TreasuryService
    let achievementService: AchievementService
    let avatarService: AvatarService
    let notificationService: NotificationService
    let appSyncCoordinator: AppSyncCoordinator
    let dataMigrationsCoordinator: DataMigrationsCoordinator
    let cacheService: CacheService?
    let syncEngine: SyncEngine?
    let toastManager: ToastManager

    init() {
        let app = AppState()
        let ck = CloudKitService()

        let isTest = TestEnvironment.isRunningUnitOrUITests
        let cache: CacheService?
        do {
            cache = try CacheService(inMemory: isTest)
        } catch {
            cache = nil
            if !isTest {
                app.cacheInitError = "Failed to initialize the local cache: \(error.localizedDescription)"
            }
        }

        let notification = NotificationService(cloudKit: ck, appState: app, cacheService: cache)
        let xp = XPService(cloudKit: ck, notificationService: notification)
        let quest = QuestService(cloudKit: ck, xpService: xp, notificationService: notification)
        let family = FamilyService(cloudKit: ck, appState: app, questService: quest)
        let treasury = TreasuryService(cloudKit: ck, notificationService: notification)
        let achievement = AchievementService(cloudKit: ck)
        let avatar = AvatarService(xp: xp)
        let appSync = AppSyncCoordinator()
        let toast = ToastManager()

        quest.cacheService = cache
        treasury.cacheService = cache
        family.cacheService = cache
        achievement.cacheService = cache
        app.cacheService = cache
        xp.cacheService = cache

        toastManager = toast

        if let cache, let container = cache.container {
            let bgActor = BackgroundCacheActor(container: container)
            syncEngine = SyncEngine(cloudKit: ck, cacheService: cache, backgroundCache: bgActor, syncCoordinator: appSync)
        } else {
            syncEngine = nil
        }

        let migrations = DataMigrationsCoordinator()
        migrations.register(
            DataMigrationsCoordinator.questNameBackfillV1(cloudKit: ck)
        )
        if let cache, let container = cache.container {
            let bgActor = BackgroundCacheActor(container: container)
            migrations.register(
                DataMigrationsCoordinator.questTargetCountBackfillV2(backgroundCache: bgActor)
            )
        }

        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "Security")
        if TestEnvironment.isRunningUnitOrUITests {
            logger.info("Tests detected — seeding mock data and setting test auth state")
            SampleData.populate(cloudKit: ck, cacheService: cache)

            ck.activeFamilyZoneID = SampleData.zoneID

            if CommandLine.arguments.contains("--onboarding") {
                app.authStatus = .onboarding
            } else if CommandLine.arguments.contains("--parent") {
                ck.activeIsOwner = true
                app.currentProfile = SampleData.parentProfile
                app.family = SampleData.family
                app.familyZoneID = SampleData.zoneID
                app.isZoneOwner = true
                app.authStatus = .authenticated
            } else {
                ck.activeIsOwner = false
                app.currentProfile = SampleData.heroProfile
                app.family = SampleData.family
                app.familyZoneID = SampleData.zoneID
                app.isZoneOwner = false
                app.authStatus = .authenticated
            }
        }

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
        cacheService = cache

        quest.toastManager = toastManager
        family.toastManager = toastManager
        treasury.toastManager = toastManager
        achievement.toastManager = toastManager
        xp.toastManager = toastManager
    }
}

@main
struct LootListApp: App {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "Security")

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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

    private var syncEngine: SyncEngine? {
        dependencies.syncEngine
    }

    private var toastManager: ToastManager {
        dependencies.toastManager
    }

    var body: some Scene {
        WindowGroup {
            rootViewContent
        }
    }

    @ViewBuilder
    private var rootViewContent: some View {
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
            .environment(syncEngine)
            .environment(toastManager)
            .task {
                if !TestEnvironment.isRunningUnitOrUITests {
                    await checkCloudKitAvailability()
                    await cloudKitService.processAbandonedZonesQueue(appState: appState)
                    await appState.restoreSession(cloudKit: cloudKitService)

                    // Bootstrap full sync: initial app launch after session
                    // restoration. At this point we have no single-family
                    // context to scope against — the purpose is a first-run
                    // pull of all data visible to this user across all
                    // families. Use syncAllFamiliesUnscoped() to make the
                    // unscoped intent explicit and prevent accidental
                    // omission of a familyRecordName in future edits.
                    await syncEngine?.syncAllFamiliesUnscoped()

                    if let zoneID = appState.familyZoneID {
                        let db = cloudKitService.database(isOwner: appState.isZoneOwner)
                        await appSyncCoordinator.registerSubscriptions(for: zoneID, in: db)
                    }

                    // Run data migrations
                    await dataMigrationsCoordinator.runPendingMigrations()
                }
            }
            .onOpenURL { url in
                handleIncomingShareURL(url)
            }
            .onChange(of: appState.familyZoneID) { _, newZoneID in
                guard let zoneID = newZoneID, !TestEnvironment.isRunningUnitOrUITests else { return }
                Task {
                    let db = cloudKitService.database(isOwner: appState.isZoneOwner)
                    await appSyncCoordinator.registerSubscriptions(for: zoneID, in: db)
                    await dataMigrationsCoordinator.runPendingMigrations()
                }
            }
            // Toast banner overlay sits above all RootView states (splash,
            // onboarding, authenticated) so services can surface errors
            // universally. Hung on `baseRoot` so both branch consumers inherit it.
            .overlay(alignment: .top) { ToastView(toastManager: toastManager) }

        if appState.cacheInitError != nil {
            // a required layer; surface the error as a controlled launch failure rather
            // than rendering blank `@Query *.Cache` views forever.
            FatalCacheErrorView(message: appState.cacheInitError ?? "Unknown cache initialization failure.")
        } else if let container = cacheService?.container {
            baseRoot.modelContainer(container)
        } else {
            // Render `baseRoot` directly without a model container (test environment path).
            baseRoot
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
        let container = CloudKitService.defaultContainer
        Task {
            do {
                let metadata = try await container.shareMetadata(for: url)
                await MainActor.run {
                    pendingShareMetadata = metadata
                }
            } catch {
                logger.error("Share metadata fetch failed: \(error, privacy: .private)")
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
    @Environment(CacheService.self) private var cacheService: CacheService
    @Environment(ToastManager.self) private var toastManager

    @State private var onboardingVM: OnboardingViewModel?
    @State private var spendingService: ManualSpendingService?

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
                TabBarView(spending: spendingService ?? ManualSpendingService(cloudKit: cloudKitService, cacheService: cacheService))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
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
                let spending = ManualSpendingService(cloudKit: cloudKitService, cacheService: cacheService)
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
