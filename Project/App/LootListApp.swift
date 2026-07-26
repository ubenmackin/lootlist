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

@main
struct LootListApp: App {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "Security")

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var appState: AppState
    @State private var cloudKitService: CloudKitService
    @State private var familyService: FamilyService
    @State private var xpService: XPService
    @State private var questService: QuestService
    @State private var treasuryService: TreasuryService
    @State private var achievementService: AchievementService
    @State private var avatarService: AvatarService
    @State private var notificationService: NotificationService
    @State private var appSyncCoordinator: AppSyncCoordinator
    @State private var dataMigrationsCoordinator: DataMigrationsCoordinator
    @State private var cacheService: CacheService?
    @State private var syncEngine: SyncEngine?

    init() {
        let app = AppState()
        let ck = CloudKitService()
        let notification = NotificationService(cloudKit: ck)
        let xp = XPService(cloudKit: ck, notificationService: notification)
        let quest = QuestService(cloudKit: ck, xpService: xp, notificationService: notification)
        let family = FamilyService(cloudKit: ck, appState: app, questService: quest)
        let treasury = TreasuryService(cloudKit: ck, notificationService: notification)
        let achievement = AchievementService(cloudKit: ck)
        let avatar = AvatarService(xp: xp)
        let appSync = AppSyncCoordinator()

        // Attempt to initialize the SwiftData local cache.
        let isTest = TestEnvironment.isRunningUnitOrUITests
        let cache = try? CacheService(inMemory: isTest)
        quest.cacheService = cache
        treasury.cacheService = cache
        family.cacheService = cache
        achievement.cacheService = cache
        app.cacheService = cache
        xp.cacheService = cache

        if let cache {
            let bgActor = BackgroundCacheActor(modelContainer: cache.container)
            _syncEngine = State(initialValue: SyncEngine(cloudKit: ck, cacheService: cache, backgroundCache: bgActor, syncCoordinator: appSync))
        } else {
            _syncEngine = State(initialValue: nil)
        }

        let migrations = DataMigrationsCoordinator()
        migrations.register(
            DataMigrationsCoordinator.questNameBackfillV1(cloudKit: ck)
        )

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

        _appState = State(initialValue: app)
        _cloudKitService = State(initialValue: ck)
        _familyService = State(initialValue: family)
        _xpService = State(initialValue: xp)
        _questService = State(initialValue: quest)
        _treasuryService = State(initialValue: treasury)
        _achievementService = State(initialValue: achievement)
        _avatarService = State(initialValue: avatar)
        _notificationService = State(initialValue: notification)
        _appSyncCoordinator = State(initialValue: appSync)
        _dataMigrationsCoordinator = State(initialValue: migrations)
        _cacheService = State(initialValue: cache)
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
            .task {
                if !TestEnvironment.isRunningUnitOrUITests {
                    await checkCloudKitAvailability()
                    await cloudKitService.processAbandonedZonesQueue(appState: appState)
                    await appState.restoreSession(cloudKit: cloudKitService)

                    // Sync all CloudKit data into local SwiftData cache
                    await syncEngine?.syncAll()

                    // Register CloudKit subscriptions for live sync
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

        if let container = cacheService?.container {
            baseRoot.modelContainer(container)
        } else if let fallback = try? ModelContainer(for: Schema([
            QuestCache.self,
            QuestTemplateCache.self,
            ProfileCache.self,
            QuestCompletionCache.self,
            FamilyCache.self,
            LedgerEntryCache.self,
            AllowancePeriodCache.self,
            AchievementCache.self,
            ProfileAchievementCache.self,
            NotificationPreferenceCache.self
        ]), configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)]) {
            baseRoot.modelContainer(fallback)
        } else {
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

    /// Temporarily stores share metadata until the onboarding VM picks it up.
    @State private var pendingShareMetadata: CKShare.Metadata?
}

private struct RootView: View {
    let pendingShareMetadata: CKShare.Metadata?

    @Environment(AppState.self) private var appState
    @Environment(CloudKitService.self) private var cloudKitService
    @Environment(FamilyService.self) private var familyService
    @Environment(CacheService.self) private var cacheService: CacheService?

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
                spendingService = ManualSpendingService(cloudKit: cloudKitService, cacheService: cacheService)
            case .restoringSession, .checkingCloudData, .detectedPreviousFamily:
                onboardingVM = nil
            }
        }
        .onChange(of: pendingShareMetadata) { _, metadata in
            onboardingVM?.pendingShareMetadata = metadata
        }
    }
}
