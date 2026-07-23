import CloudKit
import SwiftUI

struct TabBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(AvatarService.self) private var avatarService
    @Environment(XPService.self) private var xpService
    @Environment(NotificationService.self) private var notificationService

    private let spending: any SpendingService

    @State private var selectedTab: RootTab = .family

    init(spending: any SpendingService) {
        self.spending = spending
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            switch roleKind {
            case .parent:
                parentTabs
            case .hero:
                heroTabs
            case .unknown:
                emptyState
                    .tabItem { Label("…", systemImage: "questionmark.circle") }
                    .tag(RootTab.placeholder)
            }
        }
        .onAppear { reconcileDefaultSelection() }
        .onChange(of: roleKind) { _, _ in reconcileDefaultSelection() }
    }

    private var roleKind: RoleKind {
        guard let role = appState.currentProfile?.role else { return .unknown }
        return role.isParent ? .parent : .hero
    }

    enum RoleKind: Equatable { case parent, hero, unknown }

    private func reconcileDefaultSelection() {
        switch roleKind {
        case .parent:
            if !RootTab.parentTabs.contains(selectedTab) {
                selectedTab = .family
            }
        case .hero:
            if !RootTab.heroTabs.contains(selectedTab) {
                selectedTab = .quests
            }
        case .unknown:
            if selectedTab != .placeholder {
                selectedTab = .placeholder
            }
        }
    }

    @ViewBuilder
    private var parentTabs: some View {
        FamilyDashboardView()
            .tabItem {
                Label("Family", systemImage: "house.fill")
            }
            .tag(RootTab.family)

        QuestManagerView()
            .tabItem {
                Label("Manage", systemImage: "rectangle.stack.fill")
            }
            .tag(RootTab.manage)

        PayoutHistoryView()
            .tabItem {
                Label("Payouts", systemImage: "calendar.badge.checkmark")
            }
            .tag(RootTab.payouts)

        SettingsView()
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(RootTab.settings)
    }

    @ViewBuilder
    private var heroTabs: some View {
        HeroDashboardView()
            .tabItem {
                Label("Quests", systemImage: "list.bullet.clipboard")
            }
            .tag(RootTab.quests)

        TreasuryView(spending: spending)
            .tabItem {
                Label("Gold", systemImage: "circle.hexagongrid.fill")
            }
            .tag(RootTab.gold)

        TrophyRoomView()
            .tabItem {
                Label("Trophies", systemImage: "trophy.fill")
            }
            .tag(RootTab.trophies)

        ProfileView(avatarService: avatarService,
                    xpService: xpService,
                    notificationService: notificationService)
            .tabItem {
                Label("Profile", systemImage: "person.crop.circle.fill")
            }
            .tag(RootTab.profile)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.fill.questionmark")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("No character loaded")
                .font(.headline)
            Text("Sign in or pick a character to begin questing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

private enum RootTab: Hashable {
    case family
    case manage
    case payouts
    case settings

    case quests
    case gold
    case trophies
    case profile

    case placeholder

    static let parentTabs: Set<RootTab> = [.family, .manage, .payouts, .settings]

    static let heroTabs: Set<RootTab> = [.quests, .gold, .trophies, .profile]
}
