//
//  TabBarView.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import SwiftData
import SwiftUI

struct TabBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(AvatarService.self) private var avatarService
    @Environment(XPService.self) private var xpService
    @Environment(NotificationService.self) private var notificationService
    @Environment(\.scenePhase) private var scenePhase

    private let spending: SpendingService
    private let familyRecordName: String?

    @Query private var cachedCompletions: [QuestCompletionCache]

    @State private var selectedTab: RootTab = .family

    init(spending: SpendingService, familyRecordName: String? = nil) {
        self.spending = spending
        self.familyRecordName = familyRecordName

        let targetFamily = familyRecordName ?? ""
        let pendingStatus = VerificationStatus.pending.rawValue
        let completionFilter = #Predicate<QuestCompletionCache> {
            $0.familyRecordName == targetFamily &&
                $0.verificationStatus == pendingStatus
        }
        _cachedCompletions = Query(filter: completionFilter)
    }

    private var pendingCount: Int {
        cachedCompletions.count
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
        .onAppear {
            reconcileDefaultSelection()
            // Cold-start notification route retained by the owned router; adopt
            // here once session is authenticated.
            if let router = AppDependencies.shared?.notificationRouter,
               let route = router.takePendingRoute()
            {
                appState.pendingNotificationRoute = route
            } else if let fallback = NotificationRouter.shared.takePendingRoute() {
                appState.pendingNotificationRoute = fallback
            }
            checkPendingNotificationRoute(appState.pendingNotificationRoute)
            Task {
                await notificationService.updateAppBadgeCount(pendingCount: pendingCount, role: appState.currentProfile?.role)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await notificationService.updateAppBadgeCount(pendingCount: pendingCount, role: appState.currentProfile?.role)
                }
            }
        }
        .onChange(of: roleKind) { _, _ in
            reconcileDefaultSelection()
            Task {
                await notificationService.updateAppBadgeCount(pendingCount: pendingCount, role: appState.currentProfile?.role)
            }
        }
        .onChange(of: pendingCount) { _, newCount in
            Task {
                await notificationService.updateAppBadgeCount(pendingCount: newCount, role: appState.currentProfile?.role)
            }
        }
        .onChange(of: appState.pendingQuickAction) { _, action in
            guard let action else { return }
            handleQuickAction(action)
        }
        .onChange(of: appState.pendingNotificationRoute) { _, route in
            guard let route else { return }
            handleNotificationRoute(route)
        }
    }

    private func checkPendingNotificationRoute(_ route: NotificationRoute?) {
        guard let route else { return }
        handleNotificationRoute(route)
    }

    private func handleNotificationRoute(_ route: NotificationRoute) {
        switch route {
        case .pendingVerifications:
            if roleKind == .parent {
                selectedTab = .family
            }
        case .quests:
            selectedTab = (roleKind == .parent) ? .manage : .quests
        case .heroLedger:
            if roleKind == .parent {
                // Spender ledger lives under hero detail card on family dashboard.
                selectedTab = .family
            }
        }
        appState.pendingNotificationRoute = nil
    }

    private func handleQuickAction(_ action: QuickActionType) {
        defer { appState.pendingQuickAction = nil }
        switch action {
        case .processPayouts:
            if roleKind == .parent {
                selectedTab = .payouts
            }
        case .addQuickQuest, .addTemplate:
            if roleKind == .parent {
                selectedTab = .manage
            }
        case .addTransaction:
            if roleKind == .hero {
                selectedTab = .ledger
            }
        case .manageQuests:
            selectedTab = (roleKind == .parent) ? .manage : .quests
        }
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
                selectedTab = .home
            }
        case .unknown:
            if selectedTab != .placeholder {
                selectedTab = .placeholder
            }
        }
    }

    @ViewBuilder
    private var parentTabs: some View {
        let familyName = appState.family?.id.recordName

        FamilyDashboardView(spending: spending, familyRecordName: familyName)
            .id("parent-family-\(familyName ?? "")")
            .tabItem {
                Label("Family", systemImage: "house.fill")
            }
            .badge(pendingCount)
            .accessibilityLabel(pendingCount > 0 ? "Family, \(pendingCount) pending approvals" : "Family")
            .tag(RootTab.family)

        QuestManagerView(familyRecordName: familyName)
            .id("parent-manage-\(familyName ?? "")")
            .tabItem {
                Label("Manage", systemImage: "rectangle.stack.fill")
            }
            .tag(RootTab.manage)

        PayoutHistoryView(familyRecordName: familyName)
            .id("parent-payouts-\(familyName ?? "")")
            .tabItem {
                Label("Payouts", systemImage: "calendar.badge.checkmark")
            }
            .tag(RootTab.payouts)

        SettingsView(
            familyRecordName: familyName,
            profileRecordName: appState.currentProfile?.id.recordName
        )
        .tabItem {
            Label("Settings", systemImage: "gear")
        }
        .tag(RootTab.settings)
    }

    @ViewBuilder
    private var heroTabs: some View {
        let familyName = appState.family?.id.recordName

        ChildHubView(
            spending: spending,
            familyRecordName: familyName,
            profileRecordName: appState.currentProfile?.id.recordName
        )
        .id("hero-home-\(familyName ?? "")")
        .tabItem {
            Label("Home", systemImage: "house.fill")
        }
        .tag(RootTab.home)

        MyChoresView(familyRecordName: familyName)
            .id("hero-quests-\(familyName ?? "")")
            .tabItem {
                Label("Quests", systemImage: "list.bullet.clipboard")
            }
            .tag(RootTab.quests)

        ChildLedgerView(familyRecordName: familyName, profileRecordName: appState.currentProfile?.id.recordName)
            .id("hero-ledger-\(familyName ?? "")-\(appState.currentProfile?.id.recordName ?? "")")
            .tabItem {
                Label("Money", systemImage: "dollarsign.circle.fill")
            }
            .tag(RootTab.ledger)

        MyGoalsView(familyRecordName: familyName)
            .id("hero-goals-\(familyName ?? "")")
            .tabItem {
                Label("Goals", systemImage: "target")
            }
            .tag(RootTab.goals)

        ProfileView(avatarService: avatarService,
                    xpService: xpService,
                    notificationService: notificationService,
                    familyRecordName: familyName,
                    profileRecordName: appState.currentProfile?.id.recordName)
            .id("hero-profile-\(familyName ?? "")")
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
    case ledger
    case goals
    case profile

    case home

    case placeholder

    static let parentTabs: Set<RootTab> = [.family, .manage, .payouts, .settings]

    static let heroTabs: Set<RootTab> = [.home, .quests, .ledger, .goals, .profile]
}
