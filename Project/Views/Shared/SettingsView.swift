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

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(NotificationService.self) private var notificationService
    @Environment(FamilyService.self) private var familyService
    @Environment(CKSyncEngineCoordinator.self) private var syncCoordinator: CKSyncEngineCoordinator?

    @AppStorage("preferredAppearance") private var preferredAppearance: String = "system"
    @AppStorage("featureflags.rpgImmersive") private var rpgImmersive: Bool = false

    @Query private var currentProfileRows: [ProfileCache]

    @State private var selectedIcon: AppIconLock = .standard
    @State private var unlockedIconMilestones: Set<AppIconLock> = []
    @State private var activeIconName: String?

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

    var body: some View {
        NavigationStack {
            List {
                // Section 1: Guild Management
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

                #if DEBUG
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
                #endif

                // Section 3: Preferences
                Section("Preferences") {
                    // Appearance (Dark / Light / System)
                    Picker(selection: $preferredAppearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    } label: {
                        Label("Appearance", systemImage: "paintbrush.fill")
                            .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                    }

                    // Notifications
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

                // Alternate App Icons unlocked by savings-streak milestones.
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
                        }
                    }
                }

                // Classic Mode (Experimental) — RPG-era toggles gated behind
                // the immersive feature flag. When the flag is off, none of
                // these surfaces render.
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

                // Developer Tools: diagnostics, cache resets, and mock seeding.
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

                // Section 4: App Information
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
        .preferredColorScheme(colorScheme)
        .task {
            refreshAppIconState()
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
