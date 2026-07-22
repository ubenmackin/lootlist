import SwiftUI
import CloudKit

@main
struct QuestLogApp: App {

    @State private var appState = AppState()

    private let cloudKitService = CloudKitService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(cloudKitService)
                .task {
                    await checkCloudKitAvailability()
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
}

private struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(CloudKitService.self) private var cloudKitService

    var body: some View {
        switch appState.authStatus {
        case .onboarding:
            VStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("QuestLog")
                    .font(.largeTitle.bold())
                Text("Your adventure begins soon.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        case .authenticated:
            TabBarView(spending: ManualSpendingService(cloudKit: cloudKitService))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
        }
    }
}
