//
//  TabBarView.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import SwiftData
import SwiftUI

struct TabBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(AvatarService.self) private var avatarService
    @Environment(XPService.self) private var xpService
    @Environment(NotificationService.self) private var notificationService

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
            // A notification tap that arrived before this view mounted (cold
            // start) is retained by the router; adopt it here so the tab switch
            // still happens once the session is authenticated.
            if let route = NotificationRouter.shared.takePendingRoute() {
                appState.pendingNotificationRoute = route
            }
            checkPendingNotificationRoute(appState.pendingNotificationRoute)
            Task {
                await notificationService.updateAppBadgeCount(pendingCount: pendingCount)
            }
        }
        .onChange(of: roleKind) { _, _ in reconcileDefaultSelection() }
        .onChange(of: pendingCount) { _, newCount in
            Task {
                await notificationService.updateAppBadgeCount(pendingCount: newCount)
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
                selectedTab = .manage
            }
        case .quests:
            selectedTab = (roleKind == .parent) ? .manage : .quests
        case .heroLedger:
            if roleKind == .parent {
                // The spender's ledger lives under the hero's detail card on
                // the family dashboard.
                selectedTab = .family
            }
        }
        appState.pendingNotificationRoute = nil
    }

    private func handleQuickAction(_ action: QuickActionType) {
        switch action {
        case .processPayouts:
            if roleKind == .parent {
                selectedTab = .payouts
                appState.pendingQuickAction = nil
            }
        case .addQuickQuest, .addTemplate:
            if roleKind == .parent {
                selectedTab = .manage
            }
        case .addTransaction:
            if roleKind == .hero {
                selectedTab = .gold
            }
        case .manageQuests:
            selectedTab = (roleKind == .parent) ? .manage : .quests
            appState.pendingQuickAction = nil
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
            .tabItem {
                Label("Family", systemImage: "house.fill")
            }
            .tag(RootTab.family)

        QuestManagerView(familyRecordName: familyName)
            .tabItem {
                Label("Manage", systemImage: "rectangle.stack.fill")
            }
            .badge(pendingCount > 0 ? pendingCount : 0)
            .tag(RootTab.manage)

        PayoutHistoryView(familyRecordName: familyName)
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
        let familyName = appState.family?.id.recordName

        HeroHomeView(familyRecordName: familyName)
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }
            .tag(RootTab.home)

        QuestsView(familyRecordName: familyName)
            .tabItem {
                Label("Quests", systemImage: "list.bullet.clipboard")
            }
            .tag(RootTab.quests)

        TreasuryView(spending: spending, familyRecordName: familyName)
            .tabItem {
                Label("Money", systemImage: "banknote")
            }
            .tag(RootTab.gold)

        ProfileView(avatarService: avatarService,
                    xpService: xpService,
                    notificationService: notificationService,
                    familyRecordName: familyName)
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
    case profile

    case home

    case placeholder

    static let parentTabs: Set<RootTab> = [.family, .manage, .payouts, .settings]

    static let heroTabs: Set<RootTab> = [.home, .quests, .gold, .profile]
}
