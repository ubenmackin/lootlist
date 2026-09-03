//
//  SettingsView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftData
import SwiftUI

private enum AppIconLock: String, CaseIterable {
    case standard
    case week1 = "AppIcon-Week1"
    case week2 = "AppIcon-Week2"
    case week4 = "AppIcon-Week4"
    case week8 = "AppIcon-Week8"
    case week12 = "AppIcon-Week12"
    case week26 = "AppIcon-Week26"

    var displayName: String {
        switch self {
        case .standard: "Default"
        case .week1: "Fresh Start"
        case .week2: "Getting Going"
        case .week4: "Monthly Saver"
        case .week8: "Dedicated Saver"
        case .week12: "Quarter Champion"
        case .week26: "Half-Year Hero"
        }
    }

    /// The StreakCalculator.StreakMilestone raw value required to unlock this icon.
    /// Standard is always unlocked; others require reaching that many weeks
    /// of savings streak.
    var requiredStreakWeeks: Int {
        switch self {
        case .standard: 0
        case .week1: 1
        case .week2: 2
        case .week4: 4
        case .week8: 8
        case .week12: 12
        case .week26: 26
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case guild
    case roster
    case payout
    case preferences
    case notifications
    case appIcon
    case icloudSync
    case about

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .guild: "Guild Settings"
        case .roster: "Roster & Invites"
        case .payout: "Payout Settings"
        case .preferences: "Appearance"
        case .notifications: "Notifications"
        case .appIcon: "App Icon"
        case .icloudSync: "iCloud Sync"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .guild: "house.fill"
        case .roster: "person.3.fill"
        case .payout: "calendar.badge.clock"
        case .preferences: "paintbrush.fill"
        case .notifications: "bell.badge.fill"
        case .appIcon: "app.badge.fill"
        case .icloudSync: "cloud.fill"
        case .about: "info.circle.fill"
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(NotificationService.self) private var notificationService
    @Environment(FamilyService.self) private var familyService
    @Environment(CKSyncEngineCoordinator.self) private var syncCoordinator: CKSyncEngineCoordinator?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @AppStorage("preferredAppearance") private var preferredAppearance: String = "system"
    @AppStorage("featureflags.rpgImmersive") private var rpgImmersive: Bool = false

    @Query private var currentProfileRows: [ProfileCache]

    @State private var selectedIcon: AppIconLock = .standard
    @State private var unlockedIconMilestones: Set<AppIconLock> = []
    @State private var activeIconName: String?
    @State private var selectedSettingsSection: SettingsSection? = .guild
    @State private var isPayoutPolicyExpanded: Bool = false
    @State private var isSigningOut: Bool = false

    /// Family record name used to push the family filter down to SwiftData.
    /// When `nil` (no family loaded) the query returns zero rows, which is
    /// the correct behavior — there is no family to scope to.
    private let familyRecordName: String?

    private let profileRecordName: String?

    init(familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName

        // Filter queries by family at the SwiftData store layer. When familyRecordName is nil,
        // scope to an empty string ("") so zero rows are returned rather than fetching unscoped across all families.
        let targetFamily = familyRecordName ?? ""
        let targetProfile = profileRecordName ?? ""
        let currentProfileFilter = #Predicate<ProfileCache> {
            $0.recordName == targetProfile && $0.familyRecordName == targetFamily
        }
        _currentProfileRows = Query(
            filter: currentProfileFilter,
            sort: \ProfileCache.displayName
        )
    }

    /// Queried cache row for the active profile; nil when identity or family
    /// scope has no synced row yet, keeping rendering fail-closed.
    private var currentProfileRow: ProfileCache? {
        currentProfileRows.first
    }

    private var isRegular: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        Group {
            // WHY: split keeps sidebar and detail visible on iPad; compact collapses to NavigationStack for 50/50 where split would clip. Outer 1040 cap is applied via maxContentWidth in child cards.
            if isRegular {
                NavigationSplitView {
                    sidebarList
                } detail: {
                    NavigationStack {
                        detailContent
                    }
                }
            } else {
                compactList
            }
        }
        .preferredColorScheme(colorScheme)
        .task {
            // Default disclosure open on iPad so payout policy is visible without extra tap.
            // Uses .task to avoid mutating @State during view update.
            // Rotation never rewrites this afterwards so an explicit user collapse is respected.
            if horizontalSizeClass == .regular {
                isPayoutPolicyExpanded = true
            }
            refreshAppIconState()
        }
    }

    // MARK: - Sidebar (iPad)

    private var sidebarList: some View {
        List(selection: $selectedSettingsSection) {
            Section("Guild") {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Guild Settings")
                            .font(.body.weight(.semibold))
                        Text("Family name, roles, invitations, data reset")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "house.fill")
                        .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                }
                .tag(SettingsSection.guild)
                .accessibilityIdentifier("settings.guildSettings")

                Label("Roster & Invites", systemImage: "person.3.fill")
                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    .tag(SettingsSection.roster)
                    .accessibilityIdentifier("settings.rosterInvites")
            }

            Section("Payout") {
                Label("Payout Settings", systemImage: "calendar.badge.clock")
                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    .tag(SettingsSection.payout)
                    .accessibilityIdentifier("settings.payoutSettings")
            }

            Section("Preferences") {
                Label("Appearance", systemImage: "paintbrush.fill")
                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    .tag(SettingsSection.preferences)
                    .accessibilityIdentifier("settings.appearance")

                Label("Notifications", systemImage: "bell.badge.fill")
                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    .tag(SettingsSection.notifications)
                    .accessibilityIdentifier("settings.notifications")

                if UIApplication.shared.supportsAlternateIcons {
                    Label("App Icon", systemImage: "app.badge.fill")
                        .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                        .tag(SettingsSection.appIcon)
                        .accessibilityIdentifier("settings.appIcon")
                }
            }

            Section("System") {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("iCloud Sync")
                            .font(.body.weight(.semibold))
                        Text(syncStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "cloud.fill")
                        .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                }
                .tag(SettingsSection.icloudSync)
                .accessibilityIdentifier("settings.icloudSync")

                Label("About", systemImage: "info.circle.fill")
                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    .tag(SettingsSection.about)
                    .accessibilityIdentifier("settings.about")
            }
        }
        .navigationTitle("Settings")
    }

    // MARK: - Detail (iPad)

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSettingsSection {
        case .guild:
            guildDetail
                .navigationTitle("Guild Settings")
        case .roster:
            rosterDetail
                .navigationTitle("Roster & Invites")
        case .payout:
            payoutDetail
                .navigationTitle("Payout Settings")
        case .preferences:
            preferencesDetail
                .navigationTitle("Appearance")
        case .notifications:
            notificationsDetail
                .navigationTitle("Notifications")
        case .appIcon:
            appIconGridDetail
                .navigationTitle("App Icon")
        case .icloudSync:
            icloudSyncDetail
                .navigationTitle("iCloud Sync")
        case .about:
            aboutDetail
                .navigationTitle("About")
        case .none:
            guildDetail
                .navigationTitle("Guild Settings")
        }
    }

    private var guildDetail: some View {
        ScrollView {
            VStack(spacing: 18) {
                SettingsGuildHeaderHostView(familyRecordName: appState.family?.id.recordName)
                GuildDangerZoneSectionView(isSigningOut: $isSigningOut)
            }
            .padding(.vertical, 14)
        }
        .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
        .overlay {
            if isSigningOut {
                ProgressView("Signing out…")
                    .padding(24)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var rosterDetail: some View {
        SettingsRosterHostView(familyRecordName: appState.family?.id.recordName)
    }

    private var payoutDetail: some View {
        ScrollView {
            GuildPayoutDefaultsSectionView(isPayoutPolicyExpanded: $isPayoutPolicyExpanded)
                .padding(.vertical, 14)
        }
        .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
    }

    private var preferencesDetail: some View {
        Form {
            Section("Appearance") {
                Picker(selection: $preferredAppearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                } label: {
                    Label("Appearance", systemImage: "paintbrush.fill")
                        .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                }
            }

            Section {
                Toggle("RPG Immersive Mode", isOn: $rpgImmersive)
                    .onChange(of: rpgImmersive) { _, newValue in
                        FeatureFlags.rpgImmersive = newValue
                    }
            } header: {
                Text("Classic Mode (Experimental)")
            } footer: {
                Text("""
                Toggles the fantasy-RPG presentation layer: sprite avatars, \
                Hero classes, leveling, quest rarity, journey path, mascots, \
                gems, and more. Underlying services keep running — only the UI changes.
                """)
            }

            if FeatureFlags.rpgImmersive {
                Section("Developer") {
                    NavigationLink {
                        SpriteGalleryView()
                    } label: {
                        Label("Sprite Gallery", systemImage: "square.grid.2x2.fill")
                            .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var notificationsDetail: some View {
        if let row = currentProfileRow, appState.family != nil {
            NotificationSettingsView(
                notificationService: notificationService,
                profileCache: row
            )
        } else {
            ContentUnavailableView(
                "Notifications Unavailable",
                systemImage: "bell.slash.fill",
                description: Text("Sign in to a family to manage notifications.")
            )
        }
    }

    private var appIconGridDetail: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(AppIconLock.allCases, id: \.rawValue) { icon in
                    let isUnlocked = icon == .standard || unlockedIconMilestones.contains(icon)
                    Button {
                        setAppIcon(icon)
                    } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
                                    .frame(height: 120)
                                Image(systemName: isUnlocked ? "app.fill" : "lock.fill")
                                    .font(.system(size: 48))
                                    .foregroundStyle(isUnlocked ? Color(DesignSystemConstants.Colors.accentBlue) : .secondary)
                                if icon == selectedIcon {
                                    VStack {
                                        HStack {
                                            Spacer()
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                                                .background(Circle().fill(.white))
                                                .padding(8)
                                        }
                                        Spacer()
                                    }
                                }
                                if !isUnlocked {
                                    VStack {
                                        Spacer()
                                        HStack {
                                            Spacer()
                                            Image(systemName: "lock.fill")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .padding(8)
                                        }
                                    }
                                }
                            }
                            Text(icon.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isUnlocked ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(DesignSystemConstants.Colors.cardSurface))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(icon == selectedIcon ? Color(DesignSystemConstants.Colors.accentBlue).opacity(0.8) : Color.clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isUnlocked)
                    .accessibilityIdentifier("settings.appIcon-\(icon.rawValue)")
                }
            }
            .padding()
        }
        .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
    }

    private var icloudSyncDetail: some View {
        iCloudStatusView(familyRecordName: appState.family?.id.recordName)
    }

    private var aboutDetail: some View {
        Form {
            Section("About") {
                HStack {
                    Label("Version", systemImage: "info.circle.fill")
                        .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    Spacer()
                    Text(appVersionString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Family", systemImage: "shield.fill")
                        .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                    Spacer()
                    Text("\(Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "LootList") for Families")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Compact (iPhone)

    private var compactList: some View {
        NavigationStack {
            List {
                Section("Guild Management") {
                    NavigationLink {
                        GuildSettingsView(familyRecordName: appState.family?.id.recordName)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Guild Settings")
                                    .font(.body.weight(.semibold))
                                Text("Family name, roles, invitations, data reset")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "house.fill")
                                .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                        }
                    }
                }

                Section("iCloud Sync") {
                    NavigationLink {
                        iCloudStatusView(familyRecordName: appState.family?.id.recordName)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("iCloud Sync")
                                    .font(.body.weight(.semibold))
                                Text(syncStatusText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "cloud.fill")
                                .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                        }
                    }
                }

                Section("Preferences") {
                    Picker(selection: $preferredAppearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    } label: {
                        Label("Appearance", systemImage: "paintbrush.fill")
                            .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                    }

                    if let row = currentProfileRow, appState.family != nil {
                        NavigationLink {
                            NotificationSettingsView(
                                notificationService: notificationService,
                                profileCache: row
                            )
                        } label: {
                            Label("Notifications", systemImage: "bell.badge.fill")
                                .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
                        }
                    }
                }

                if UIApplication.shared.supportsAlternateIcons {
                    Section("App Icon") {
                        ForEach(AppIconLock.allCases, id: \.rawValue) { icon in
                            let isUnlocked = icon == .standard
                                || unlockedIconMilestones.contains(icon)

                            Button {
                                setAppIcon(icon)
                            } label: {
                                HStack {
                                    Text(icon.displayName)
                                        .font(.body)
                                        .foregroundStyle(isUnlocked ? .primary : .secondary)

                                    Spacer()

                                    if icon == selectedIcon {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                                    }

                                    if !isUnlocked {
                                        Image(systemName: "lock.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(!isUnlocked)
                            .accessibilityIdentifier("settings.appIcon-\(icon.rawValue)")
                        }
                    }
                }

                if FeatureFlags.rpgImmersive {
                    Section {
                        Toggle("RPG Immersive Mode", isOn: $rpgImmersive)
                            .onChange(of: rpgImmersive) { _, newValue in
                                FeatureFlags.rpgImmersive = newValue
                            }
                    } header: {
                        Text("Classic Mode (Experimental)")
                    } footer: {
                        Text("""
                        Toggles the fantasy-RPG presentation layer: sprite avatars, \
                        Hero classes, leveling, quest rarity, journey path, mascots, \
                        gems, and more. Underlying services keep running — only the UI changes.
                        """)
                    }
                }

                if FeatureFlags.rpgImmersive {
                    Section("Developer") {
                        NavigationLink {
                            SpriteGalleryView()
                        } label: {
                            Label("Sprite Gallery", systemImage: "square.grid.2x2.fill")
                                .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                        }
                    }
                }

                Section("About") {
                    HStack {
                        Label("Version", systemImage: "info.circle.fill")
                            .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                        Spacer()
                        Text(appVersionString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Family", systemImage: "shield.fill")
                            .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                        Spacer()
                        Text("\(Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "LootList") for Families")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - App Icon Management

    private func refreshAppIconState() {
        activeIconName = UIApplication.shared.alternateIconName
        if let name = activeIconName, let icon = AppIconLock.allCases.first(where: { $0.rawValue == name }) {
            selectedIcon = icon
        } else {
            selectedIcon = .standard
        }
        reconcileUnlockedMilestones()
    }

    /// Reads the highest savings-streak milestone reached (device-local
    /// UserDefaults) and marks all icons up to that tier as unlocked.
    private func reconcileUnlockedMilestones() {
        let maxWeeks = UserDefaults.standard.integer(forKey: "appicon.maxSavingsStreakWeeks")
        var unlocked: Set<AppIconLock> = []
        for icon in AppIconLock.allCases where icon.requiredStreakWeeks <= maxWeeks {
            unlocked.insert(icon)
        }
        unlockedIconMilestones = unlocked
    }

    private func setAppIcon(_ icon: AppIconLock) {
        let name: String? = icon == .standard ? nil : icon.rawValue
        let currentName = UIApplication.shared.alternateIconName
        guard name != currentName else { return }
        UIApplication.shared.setAlternateIconName(name) { error in
            // Completion runs off the main actor; hop back to mutate @State.
            Task { @MainActor in
                if error != nil {
                    // Icon change failed — silently ignore; the picker stays on the
                    // last successfully set icon.
                    return
                }
                activeIconName = name
                selectedIcon = icon
            }
        }
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var syncStatusText: String {
        if syncCoordinator?.syncError != nil {
            "Sync failed — tap to retry"
        } else if syncCoordinator?.isSyncing == true {
            "Syncing…"
        } else if (syncCoordinator?.pendingUploadCount ?? 0) > 0 {
            "\(syncCoordinator?.pendingUploadCount ?? 0) pending upload\(syncCoordinator?.pendingUploadCount == 1 ? "" : "s")"
        } else if let last = syncCoordinator?.lastSyncedAt {
            "Last synced \(last.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))"
        } else if syncCoordinator == nil {
            "Unavailable"
        } else {
            "Not yet synced"
        }
    }

    private var colorScheme: ColorScheme? {
        switch preferredAppearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}
