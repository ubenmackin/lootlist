import CloudKit
import os
import SwiftUI

@main
struct LootListApp: App {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "Security")

    @State private var appState: AppState
    @State private var cloudKitService: CloudKitService
    @State private var familyService: FamilyService
    @State private var xpService: XPService
    @State private var questService: QuestService
    @State private var treasuryService: TreasuryService
    @State private var achievementService: AchievementService
    @State private var avatarService: AvatarService
    @State private var notificationService: NotificationService

    init() {
        let app = AppState()
        let ck = CloudKitService()
        let family = FamilyService(cloudKit: ck, appState: app)
        let notification = NotificationService(cloudKit: ck)
        let xp = XPService(cloudKit: ck, notificationService: notification)
        let quest = QuestService(cloudKit: ck, xpService: xp, notificationService: notification)
        let treasury = TreasuryService(cloudKit: ck, notificationService: notification)
        let achievement = AchievementService(cloudKit: ck)
        let avatar = AvatarService(xp: xp)

        if CommandLine.arguments.contains("--uitesting") {
            let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
            let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
            let userRecordID = CKRecord.ID(recordName: "user1", zoneID: zoneID)
            var heroProfile = Profile(
                displayName: "Sir Testalot",
                avatarClass: .knight,
                avatarPresetID: "knight_01",
                role: CommandLine.arguments.contains("--parent") ? .guildMaster : .hero,
                iCloudUserID: userRecordID,
                family: familyRef,
                id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
            )
            heroProfile.xp = 1200
            heroProfile.level = 5

            if CommandLine.arguments.contains("--onboarding") {
                app.authStatus = .onboarding
            } else {
                app.currentProfile = heroProfile
                app.family = Family(name: "Test Guild", createdBy: userRecordID, id: CKRecord.ID(recordName: "fam1", zoneID: zoneID))
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
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(cloudKitService)
                .environment(familyService)
                .environment(xpService)
                .environment(questService)
                .environment(treasuryService)
                .environment(achievementService)
                .environment(avatarService)
                .environment(notificationService)
                .task {
                    if !CommandLine.arguments.contains("--uitesting") {
                        await checkCloudKitAvailability()
                        await cloudKitService.processAbandonedZonesQueue(appState: appState)
                        await appState.restoreSession(cloudKit: cloudKitService)
                    }
                }
                .onOpenURL { url in
                    handleIncomingShareURL(url)
                }
        }
    }

    private func checkCloudKitAvailability() async {
        let container = CKContainer.default()

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
        let container = CKContainer.default()
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
    @Environment(AppState.self) private var appState
    @Environment(CloudKitService.self) private var cloudKitService
    @Environment(FamilyService.self) private var familyService

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
            case .detectedPreviousFamily(let family, let profile, let zoneID, let isOwner):
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
                    TabBarView(spending: spendingService)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemBackground))
                }
            }
        }
        .task(id: appState.authStatus) {
            switch appState.authStatus {
            case .onboarding:
                onboardingVM = OnboardingViewModel(
                    familyService: familyService,
                    appState: appState
                )
                spendingService = nil
            case .authenticated:
                onboardingVM = nil
                spendingService = ManualSpendingService(cloudKit: cloudKitService)
            case .restoringSession, .checkingCloudData, .detectedPreviousFamily:
                onboardingVM = nil
            }
        }
    }
}
