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

    private var soundManager: SoundManager {
        dependencies.soundManager
    }

    private var gemService: GemService {
        dependencies.gemService
    }

    private var lootDropService: LootDropService {
        dependencies.lootDropService
    }

    private var dailyLoginService: DailyLoginService {
        dependencies.dailyLoginService
    }

    private var bonusObjectiveService: BonusObjectiveService {
        dependencies.bonusObjectiveService
    }

    private var equipmentService: EquipmentService {
        dependencies.equipmentService
    }

    private var spendingService: SpendingService {
        dependencies.spendingService
    }

    private var interestService: InterestService {
        dependencies.interestService
    }

    private var matchService: MatchService {
        dependencies.matchService
    }

    private var ledgerImportService: LedgerImportService {
        dependencies.ledgerImportService
    }

    private var goalService: GoalService {
        dependencies.goalService
    }

    private var bucketService: BucketService {
        dependencies.bucketService
    }

    private var lifecycleCoordinator: AppLifecycleCoordinator {
        dependencies.lifecycleCoordinator
    }

    var body: some Scene {
        WindowGroup {
            rootViewContent
        }
    }

    @ViewBuilder
    private var rootViewContent: some View {
        if TestEnvironment.isRunningUnitTests {
            Color.clear
        } else if let error = appState.cacheInitError {
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
                .task {
                    if !TestEnvironment.isRunningUnitOrUITests {
                        await lifecycleCoordinator.performInitialBootstrap()
                    }
                }
                .onOpenURL { url in
                    handleIncomingShareURL(url)
                }
                .task(id: "\(appState.authStatus)|\(appState.familyZoneID?.zoneName ?? "")") {
                    guard appState.authStatus == .authenticated,
                          appState.familyZoneID != nil,
                          !TestEnvironment.isRunningUnitOrUITests
                    else { return }
                    await lifecycleCoordinator.performFamilyZoneChange()
                }
                .task(id: scenePhase) {
                    guard scenePhase == .active, !TestEnvironment.isRunningUnitOrUITests else { return }
                    await lifecycleCoordinator.performForegroundSync()
                }
                // Toast banner overlay sits above all RootView states (splash,
                // onboarding, authenticated) so services can surface errors
                // universally.
                .toastOverlay()
                // UI tests force light or dark via `--uitest-appearance` so a
                // single simulator captures both modes per run.
                .preferredColorScheme(TestEnvironment.preferredAppearanceOverride)
                .task {
                    for await _ in NotificationCenter.default.notifications(named: .familyAccessRevoked) {
                        toastManager.show(message: "You were removed from this Guild.", type: .warning)
                    }
                }
                // Celebration fullscreen overlay sits above the toast layer so
                // trophy unlocks and streak milestones take visual priority.
                .celebrationOverlay()
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
                .environment(lifecycleCoordinator)
                .environment(networkMonitor)
                .environment(toastManager)
                .environment(celebrationManager)
                .environment(soundManager)
                .environment(gemService)
                .environment(lootDropService)
                .environment(dailyLoginService)
                .environment(bonusObjectiveService)
                .environment(equipmentService)
                .environment(spendingService)
                .environment(interestService)
                .environment(matchService)
                .environment(ledgerImportService)
                .environment(goalService)
                .environment(bucketService)

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
                pendingShareMetadata = metadata
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
    @Environment(FamilyService.self) private var familyService
    @Environment(SpendingService.self) private var spendingService: SpendingService
    @Environment(CKSyncEngineCoordinator.self) private var syncCoordinator: CKSyncEngineCoordinator

    @State private var onboardingVM: OnboardingViewModel?

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
                // Pre-cache bootstrapping path: AppState holds the authoritative CloudKit domain models
                // but we map them to Cache models to keep DetectedFamilyView decoupled from CloudKit structs.
                DetectedFamilyView(
                    familyCache: FamilyCache(from: family),
                    profileCache: ProfileCache(from: profile),
                    zoneIDString: zoneID.zoneName,
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
                TabBarView(spending: spendingService, familyRecordName: appState.family?.id.recordName)
                    .id(appState.family?.id.recordName ?? "none")
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
                    appState: appState,
                    syncCoordinator: syncCoordinator
                )
                vm.pendingShareMetadata = pendingShareMetadata
                onboardingVM = vm
            case .authenticated, .restoringSession, .checkingCloudData, .detectedPreviousFamily, .offlineEmptyCache:
                onboardingVM = nil
            }
        }
        .onChange(of: pendingShareMetadata) { _, metadata in
            onboardingVM?.pendingShareMetadata = metadata
        }
    }
}
