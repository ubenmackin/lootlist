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
    private let profileRecordName: String?

    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var currentProfileRows: [ProfileCache]

    @State private var selectedTab: RootTab = .family

    init(spending: SpendingService, familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.spending = spending
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName

        let targetFamily = familyRecordName ?? ""
        let completionFilter = QuestCompletionCache.pendingPredicate(familyRecordName: targetFamily)
        // WHY stable sort: secondary recordName keeps badge count ordering deterministic across sync reorders.
        _cachedCompletions = Query(filter: completionFilter, sort: HubQueryProvider.completionSort())
        // WHY: single-row scope keeps role and displayName cache-derived instead of session-derived.
        if let targetProfile = profileRecordName.sanitizedNilIfEmpty {
            _currentProfileRows = Query(
                filter: ProfileCache.recordPredicate(recordName: targetProfile, familyRecordName: targetFamily),
                sort: HubQueryProvider.profileSort()
            )
        } else {
            // WHY: family fallback keeps tab gating live before the profile param propagates; row still resolves via session identity.
            _currentProfileRows = Query(
                filter: ProfileCache.familyPredicate(familyRecordName: targetFamily),
                sort: HubQueryProvider.profileSort()
            )
        }
    }

    /// Queried cache row for the active viewer; nil when scope has no synced row (fail-closed rendering).
    private var currentProfileRow: ProfileCache? {
        // WHY: resolver keeps empty-scope fail-closed while session identity bridges bootstrap before the param propagates.
        ProfileRowResolver.resolve(rows: currentProfileRows, targetRecordName: profileRecordName ?? appState.currentProfile?.id.recordName)
    }

    /// Viewer role derived from cache so tab gating never reads session domain state.
    private var viewerRole: UserRole? {
        currentProfileRow?.roleEnum
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
        .tabViewStyle(.sidebarAdaptable)
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
                await notificationService.updateAppBadgeCount(pendingCount: pendingCount, role: viewerRole)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await notificationService.updateAppBadgeCount(pendingCount: pendingCount, role: viewerRole)
                }
            }
        }
        .onChange(of: roleKind) { _, _ in
            reconcileDefaultSelection()
            Task {
                await notificationService.updateAppBadgeCount(pendingCount: pendingCount, role: viewerRole)
            }
        }
        .onChange(of: pendingCount) { _, newCount in
            Task {
                await notificationService.updateAppBadgeCount(pendingCount: newCount, role: viewerRole)
            }
        }
        .onChange(of: currentProfileRows) { _, _ in
            reconcileDefaultSelection()
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
        // WHY: row-derived role keeps tab gating cache-bound with fail-closed unknown scope.
        guard let role = viewerRole else { return .unknown }
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
        // WHY: row-first identity keeps tab scope cache-bound with session fallback during bootstrap.
        let familyName = familyRecordName ?? appState.family?.id.recordName
        let profileName = profileRecordName ?? currentProfileRow?.recordName

        FamilyDashboardView(spending: spending, familyRecordName: familyName, profileRecordName: profileName)
            .id("parent-family-\(familyName ?? "")-\(profileName ?? "")")
            .tabItem {
                Label("Family", systemImage: "house.fill")
            }
            .badge(pendingCount)
            .accessibilityLabel(pendingCount > 0 ? "Family, \(pendingCount) pending approvals" : "Family")
            .tag(RootTab.family)

        QuestManagerView(familyRecordName: familyName)
            .id("parent-manage-\(familyName ?? "")-\(profileName ?? "")")
            .tabItem {
                Label("Manage", systemImage: "rectangle.stack.fill")
            }
            .tag(RootTab.manage)

        PayoutHistoryView(familyRecordName: familyName, profileRecordName: profileName)
            .id("parent-payouts-\(familyName ?? "")-\(profileName ?? "")")
            .tabItem {
                Label("Payouts", systemImage: "calendar.badge.checkmark")
            }
            .tag(RootTab.payouts)

        SettingsView(
            familyRecordName: familyName,
            profileRecordName: profileName
        )
        .id("parent-settings-\(familyName ?? "")-\(profileName ?? "")")
        .tabItem {
            Label("Settings", systemImage: "gear")
        }
        .tag(RootTab.settings)
    }

    @ViewBuilder
    private var heroTabs: some View {
        // WHY: row-first identity keeps tab scope cache-bound with session fallback during bootstrap.
        let familyName = familyRecordName ?? appState.family?.id.recordName
        let profileName = profileRecordName ?? currentProfileRow?.recordName

        ChildHubView(
            spending: spending,
            familyRecordName: familyName,
            profileRecordName: profileName
        )
        .id("hero-home-\(familyName ?? "")-\(profileName ?? "")")
        .tabItem {
            Label("Home", systemImage: "house.fill")
        }
        .tag(RootTab.home)

        MyChoresView(familyRecordName: familyName, profileRecordName: profileName)
            .id("hero-quests-\(familyName ?? "")-\(profileName ?? "")")
            .tabItem {
                Label("Quests", systemImage: "list.bullet.clipboard")
            }
            .tag(RootTab.quests)

        ChildLedgerView(familyRecordName: familyName, profileRecordName: profileName)
            .id("hero-ledger-\(familyName ?? "")-\(profileName ?? "")")
            .tabItem {
                Label("Money", systemImage: "dollarsign.circle.fill")
            }
            .tag(RootTab.ledger)

        MyGoalsView(familyRecordName: familyName, profileRecordName: profileName)
            .id("hero-goals-\(familyName ?? "")-\(profileName ?? "")")
            .tabItem {
                Label("Goals", systemImage: "target")
            }
            .tag(RootTab.goals)

        ProfileView(avatarService: avatarService,
                    xpService: xpService,
                    notificationService: notificationService,
                    familyRecordName: familyName,
                    profileRecordName: profileName)
            .id("hero-profile-\(familyName ?? "")-\(profileName ?? "")")
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
        .maxBannerWidth()
        .frame(maxHeight: .infinity)
        .background(Color(DesignSystemConstants.Colors.background))
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
