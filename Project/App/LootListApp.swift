import CloudKit
import SwiftUI

@main
struct LootListApp: App {
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
                    await checkCloudKitAvailability()
                    await appState.restoreSession(cloudKit: cloudKitService)
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
                appState.signOut()
            @unknown default:
                appState.signOut()
            }
        } catch {
            appState.signOut()
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
                print("Failed to fetch share metadata for URL \(url): \(error)")
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

    var body: some View {
        Group {
            switch appState.authStatus {
            case .restoringSession:
                AppLaunchSplashScreen()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .onboarding:
                if let onboardingVM {
                    WelcomeView(viewModel: onboardingVM)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemBackground))
                }
            case .authenticated:
                TabBarView(spending: ManualSpendingService(cloudKit: cloudKitService))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
            }
        }
        .task(id: appState.authStatus) {
            switch appState.authStatus {
            case .onboarding:
                onboardingVM = OnboardingViewModel(
                    familyService: familyService,
                    appState: appState
                )
            case .authenticated, .restoringSession:
                onboardingVM = nil
            }
        }
    }
}
