//
//  ProfileView.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import os
import PhotosUI
import SwiftData
import SwiftUI

@MainActor
struct ProfileView: View {
    private let avatarService: AvatarService

    private let xpService: XPService

    private let notificationService: NotificationService

    @Environment(ToastManager.self) private var toastManager

    @Environment(AppState.self) private var appState

    @Environment(CloudKitService.self) private var cloudKitService

    @Environment(CKSyncEngineCoordinator.self) private var syncCoordinator: CKSyncEngineCoordinator?

    @Environment(FamilyService.self) private var familyService

    @Environment(QuestService.self) private var questService

    @Environment(AchievementService.self) private var achievementService

    @Query private var cachedAchievements: [AchievementCache]
    @Query private var cachedProfileAchievements: [ProfileAchievementCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedProfiles: [ProfileCache]
    @Query private var currentProfileRows: [ProfileCache]

    @State private var showingEditName: Bool = false

    @State private var showingEditAvatar: Bool = false

    @State private var draftName: String = ""

    @State private var showingSignOutConfirm: Bool = false

    @State private var isSigningOut: Bool = false

    @State private var viewModel = ProfileViewModel()

    /// Family record name used to push the family filter down to SwiftData.
    /// When `nil` (no family loaded) the queries return zero rows, which is
    /// the correct behavior — there is no family to scope to.
    private let familyRecordName: String?

    private let profileRecordName: String?

    init(avatarService: AvatarService,
         xpService: XPService,
         notificationService: NotificationService,
         familyRecordName: String? = nil,
         profileRecordName: String? = nil)
    {
        self.avatarService = avatarService
        self.xpService = xpService
        self.notificationService = notificationService
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName

        // Filter queries by family at the SwiftData store layer. When familyRecordName is nil,
        // scope to an empty string ("") so zero rows are returned rather than fetching unscoped across all families.
        let targetFamily = familyRecordName ?? ""
        let targetProfile = profileRecordName ?? ""
        let achievementFilter = #Predicate<AchievementCache> { $0.familyRecordName == targetFamily }
        let profileAchievementFilter = #Predicate<ProfileAchievementCache> { $0.familyRecordName == targetFamily }
        let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily }
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily }
        let profileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }
        let currentProfileFilter = #Predicate<ProfileCache> {
            $0.recordName == targetProfile && $0.familyRecordName == targetFamily
        }
        _cachedAchievements = Query(
            filter: achievementFilter,
            sort: \AchievementCache.name
        )
        _cachedProfileAchievements = Query(
            filter: profileAchievementFilter,
            sort: \ProfileAchievementCache.earnedDate,
            order: .reverse
        )
        _cachedCompletions = Query(
            filter: completionFilter,
            sort: \QuestCompletionCache.completedDate,
            order: .reverse
        )
        _cachedLedgers = Query(
            filter: ledgerFilter,
            sort: \LedgerEntryCache.date,
            order: .reverse
        )
        _cachedQuests = Query(
            filter: questFilter,
            sort: \QuestCache.weekOf,
            order: .reverse
        )
        _cachedProfiles = Query(
            filter: profileFilter,
            sort: \ProfileCache.displayName
        )
        _currentProfileRows = Query(
            filter: currentProfileFilter,
            sort: \ProfileCache.displayName
        )
    }

    /// Queried cache row for the active profile. Nil when the session identity
    /// or family scope has no synced row yet, keeping rendering fail-closed
    /// instead of falling back to the session snapshot.
    private var currentProfileRow: ProfileCache? {
        currentProfileRows.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let row = currentProfileRow {
                        characterCard(row: row)
                        actionsSection(row: row)
                        aboutSection
                    } else {
                        emptyState
                    }
                }
                .padding(.vertical, 20)
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .alert("Sign Out?", isPresented: $showingSignOutConfirm) {
                Button("Sign Out", role: .destructive) {
                    isSigningOut = true
                    Task {
                        await appState.signOutAndDiscover(cloudKit: cloudKitService, syncCoordinator: syncCoordinator)
                        isSigningOut = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your local session will end, and your Guild stays synced in iCloud. "
                    + "If an existing Guild is found, the app will reconnect you to it; "
                    + "otherwise you'll return to the Welcome screen.")
            }
            .overlay {
                if isSigningOut {
                    ProgressView("Signing out…")
                        .padding(24)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            .sheet(isPresented: $showingEditName) {
                if let row = currentProfileRow, row.roleEnum == .hero {
                    editNameSheet()
                }
            }
            .sheet(isPresented: $showingEditAvatar) {
                if let row = currentProfileRow {
                    EditAvatarSheet(profileCache: row)
                }
            }
            .task {
                recomputeCharacterFromCache()
                viewModel.refreshFreshness(
                    profile: appState.currentProfile,
                    family: appState.family,
                    achievementService: achievementService,
                    appState: appState
                )
            }
            .onChange(of: cachedProfileAchievements) { _, _ in recomputeCharacterFromCache() }
            .onChange(of: cachedCompletions) { _, _ in recomputeCharacterFromCache() }
            .onChange(of: cachedLedgers) { _, _ in recomputeCharacterFromCache() }
            .onChange(of: cachedAchievements) { _, _ in recomputeCharacterFromCache() }
            .onChange(of: cachedQuests) { _, _ in recomputeCharacterFromCache() }
            .onChange(of: cachedProfiles) { _, _ in recomputeCharacterFromCache() }
        }
    }

    private func recomputeCharacterFromCache() {
        appState.updateCurrentProfileFromCache()
        viewModel.recomputeCharacterFromCache(
            profile: appState.currentProfile,
            completions: cachedCompletions,
            ledgers: cachedLedgers,
            quests: cachedQuests,
            profileAchievements: cachedProfileAchievements,
            achievements: cachedAchievements,
            zoneID: appState.currentProfile?.id.zoneID ?? appState.family?.id.zoneID ?? CKRecordZone.default().zoneID,
            // Payout cycle anchoring: profile override → family → Sunday default.
            payoutDay: appState.currentProfile?.payoutDay ?? appState.family?.payoutDay ?? .sunday
        )
    }

    private func characterCard(row: ProfileCache) -> some View {
        VStack(spacing: 14) {
            if FeatureFlags.rpgImmersive {
                rpgCharacterCard(row: row)
            } else {
                utilityCharacterCard(row: row)
            }

            HStack(spacing: 12) {
                Button {
                    showingEditAvatar = true
                } label: {
                    Label("Change Avatar", systemImage: "photo.badge.plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Color(DesignSystemConstants.Colors.pendingAmber))
                .accessibilityIdentifier("profile.changeAvatarButton")

                if row.roleEnum == .hero {
                    Button {
                        draftName = row.displayName
                        showingEditName = true
                    } label: {
                        Label("Rename", systemImage: "pencil.line")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(Color(DesignSystemConstants.Colors.pendingAmber))
                    .accessibilityIdentifier("profile.renameButton")
                }
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                LinearGradient(
                    colors: [
                        Color(DesignSystemConstants.Colors.accentBlue).opacity(0.35),
                        Color(DesignSystemConstants.Colors.accentBlue).opacity(0.30),
                        Color(DesignSystemConstants.Colors.accentBlue).opacity(0.50)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.20), .clear],
                    center: .center,
                    startRadius: 0, endRadius: 0.85
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.45), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.top, 4)
    }

    /// Utility-first card: emoji avatar, name, role, and savings streak.
    @ViewBuilder
    private func utilityCharacterCard(row: ProfileCache) -> some View {
        Text(row.avatarEmoji ?? "🧑")
            .font(.system(size: 56))

        Text(row.displayName)
            .font(.title2.bold())
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.75)

        Text((row.roleEnum ?? .hero).displayName)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.85))

        // Savings-streak badge strip: shows quest streak and savings streak.
        savingsStreakStrip
    }

    /// RPG-era card: sprite avatar, class, level, title, XP bar.
    @ViewBuilder
    private func rpgCharacterCard(row: ProfileCache) -> some View {
        let spec = avatarService.renderSpec(for: row)
        let progress = xpService.levelProgress(profileCache: row)

        AvatarView(spec: spec, size: .large, showsNameAndTitle: false)
        nameBlock(row: row, spec: spec)
        levelBadge(row: row)
        xpBlock(progress: progress)
    }

    /// Streak badges: quest-completion streak and weekly savings-split streak.
    private var savingsStreakStrip: some View {
        let questStreak = viewModel.streak ?? 0
        let savingsStreak = viewModel.savingsStreak ?? 0

        return HStack(spacing: 10) {
            streakBadge(
                icon: "flame.fill",
                color: Color(DesignSystemConstants.Colors.pendingAmber),
                count: questStreak,
                label: questStreak == 1 ? "day" : "days"
            )
            streakBadge(
                icon: "banknote.fill",
                color: Color(DesignSystemConstants.Colors.primaryGreen),
                count: savingsStreak,
                label: savingsStreak == 1 ? "wk saving" : "wks saving"
            )
        }
    }

    private func streakBadge(icon: String,
                             color: Color,
                             count: Int,
                             label: String) -> some View
    {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
            Text("\(count) \(label)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.18))
        )
    }

    private func nameBlock(row: ProfileCache, spec: AvatarRenderSpec) -> some View {
        VStack(spacing: 4) {
            Text(row.displayName)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(spec.levelTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
            Text("\(row.avatarClassEnum?.displayName ?? (row.roleEnum ?? .hero).genericRoleName) • \((row.roleEnum ?? .hero).displayName)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func levelBadge(row: ProfileCache) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "number")
                .font(.caption.weight(.bold))
            Text("\(row.level)")
                .font(.callout.weight(.bold))
            Text("Level")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.18))
                .overlay(
                    Capsule().strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.70), lineWidth: 1)
                )
        )
    }

    private func xpBlock(progress: LevelProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Experience")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text("\(progress.xpIntoCurrentLevel) / \(progress.xpForNextLevel) XP")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
            }
            ProgressBar(
                value: Double(progress.xpIntoCurrentLevel),
                maximum: Double(max(progress.xpForNextLevel, 1)),
                label: nil,
                tint: Color(DesignSystemConstants.Colors.pendingAmber),
                height: 10
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            // Structural scrim: darkens the XP block so white copy stays legible over the gradient card.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
    }

    private func actionsSection(row: ProfileCache) -> some View {
        VStack(spacing: 0) {
            // Character Sheet is an RPG-era detail screen; hidden while the
            // immersive layer is off.
            if FeatureFlags.rpgImmersive {
                NavigationLink {
                    CharacterSheetView(
                        profileCache: row,
                        avatarService: avatarService,
                        xpService: xpService,
                        streak: viewModel.streak,
                        goldBalance: viewModel.goldBalance,
                        earnedAchievements: viewModel.earnedAchievements,
                        onSaveDisplayName: { newName in
                            guard row.roleEnum == .hero, let current = appState.currentProfile else { return }
                            Task {
                                do {
                                    let updated = try await familyService.updateProfileDisplayName(profile: current, newName: newName)
                                    appState.currentProfile = updated
                                } catch {
                                    toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                                }
                            }
                        }
                    )
                } label: {
                    actionRow(
                        icon: "doc.text.magnifyingglass",
                        title: "Open Character Sheet",
                        subtitle: "Detailed stats, accessories, and trophies"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.openCharacterSheet")
            }

            if row.roleEnum == .hero {
                // Gem Shop is an RPG-era surface; hidden while the immersive layer is off.
                if FeatureFlags.rpgImmersive {
                    Divider().padding(.leading, 56)

                    NavigationLink {
                        GemShopView()
                    } label: {
                        actionRow(
                            icon: "sparkles",
                            title: "Gem Shop",
                            subtitle: "Cosmetics, gear, and companion pets",
                            tint: Color(DesignSystemConstants.Colors.pendingAmber)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.gemShop")
                }

                // Only show the divider before Trophy Room when there is
                // preceding content (Character Sheet or Gem Shop).
                if FeatureFlags.rpgImmersive {
                    Divider().padding(.leading, 56)
                }

                NavigationLink {
                    TrophyRoomView(
                        familyRecordName: familyRecordName ?? appState.family?.id.recordName,
                        profileRecordName: profileRecordName ?? appState.currentProfile?.id.recordName
                    )
                } label: {
                    actionRow(
                        icon: "trophy.fill",
                        title: "Trophies",
                        subtitle: "Hall of Heroes — view unlocked achievements",
                        tint: Color(DesignSystemConstants.Colors.pendingAmber)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.trophies")

                Divider().padding(.leading, 56)
            } else {
                Divider().padding(.leading, 56)
            }

            Divider().padding(.leading, 56)

            NavigationLink {
                if appState.family != nil {
                    NotificationSettingsView(
                        notificationService: notificationService,
                        profileCache: row
                    )
                }
            } label: {
                actionRow(
                    icon: "bell.badge",
                    title: "Notification Settings",
                    subtitle: "Per-event toggles: in-app + push"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profile.notificationSettings")

            Divider().padding(.leading, 56)

            Button {
                showingSignOutConfirm = true
            } label: {
                actionRow(
                    icon: "rectangle.portrait.and.arrow.right",
                    title: "Sign Out",
                    subtitle: "Sign out of this device; your Guild stays in iCloud",
                    tint: Color(DesignSystemConstants.Colors.dangerRed)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profile.signOut")
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal)
    }

    private func actionRow(icon: String,
                           title: String,
                           subtitle: String,
                           tint: Color = .accentColor) -> some View
    {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var aboutSection: some View {
        VStack(spacing: 0) {
            aboutRow(label: "Version", value: appVersion)
            Divider().padding(.leading, 56)
            aboutRow(label: "Build", value: buildNumber)
            Divider().padding(.leading, 56)
            aboutRow(label: "Loot List", value: "Family chore tracker")
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal)
    }

    private func aboutRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var appVersion: String {
        let versionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return versionString.map { "v\($0)" } ?? "v1.0"
    }

    private var buildNumber: String {
        let buildString = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return buildString ?? "1"
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.fill.questionmark")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No Character Loaded")
                .font(.title3.bold())
            Text("Sign in or pick a character to begin questing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.top, 60)
    }

    private func editNameSheet() -> some View {
        NavigationStack {
            Form {
                Section("Character Name") {
                    TextField("Sir Cleanup", text: $draftName)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("profile.displayNameField")
                }
                Section {
                    Text("Your Guildmates will see this name on the Hall of Heroes and Hero Status board.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Rename Character")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingEditName = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        showingEditName = false
                        guard let current = appState.currentProfile else { return }
                        Task {
                            do {
                                let updated = try await familyService.updateProfileDisplayName(profile: current, newName: trimmed)
                                appState.currentProfile = updated
                            } catch {
                                toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                            }
                        }
                    }
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("profile.displayNameSave")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

@MainActor
@Observable
final class ProfileViewModel {
    var streak: Int?
    var savingsStreak: Int?
    var goldBalance: Double?
    var earnedAchievements: [Achievement] = []

    func reset() {
        streak = nil
        savingsStreak = nil
        goldBalance = nil
        earnedAchievements = []
    }

    func recomputeCharacterFromCache(
        profile: Profile?,
        completions: [QuestCompletionCache],
        ledgers: [LedgerEntryCache],
        quests _: [QuestCache],
        profileAchievements: [ProfileAchievementCache],
        achievements: [AchievementCache],
        zoneID: CKRecordZone.ID,
        payoutDay: PayoutDay
    ) {
        guard let profile else {
            reset()
            return
        }
        let profileName = profile.id.recordName

        let heroCompletions = completions.filter { $0.completerRecordName == profileName }
        streak = StreakCalculator.computeStreak(from: heroCompletions)

        // Savings streak: weeks where the hero contributed to save buckets.
        savingsStreak = StreakCalculator.computeSavingsStreak(
            from: ledgers,
            profileRecordName: profileName,
            payoutDay: payoutDay
        )

        // Persist the highest savings-streak milestone reached so alternate app
        // icon eligibility can be read from Settings (device-local UserDefaults).
        if let streak = savingsStreak {
            let stored = UserDefaults.standard.integer(forKey: "appicon.maxSavingsStreakWeeks")
            if streak > stored {
                UserDefaults.standard.set(streak, forKey: "appicon.maxSavingsStreakWeeks")
            }
        }

        // Balance is derived directly from ledger entry sum.
        let profileLedgers = ledgers.filter { $0.profileRecordName == profileName }
        goldBalance = profileLedgers.reduce(0.0) { $0 + $1.amount }

        let earnedNames = Set(
            profileAchievements
                .filter { $0.profileRecordName == profileName }
                .map(\.achievementRecordName)
        )
        earnedAchievements = achievements
            .filter { earnedNames.contains($0.recordName) }
            .map { $0.toAchievement(zoneID: zoneID) }
    }

    func refreshFreshness(
        profile: Profile?,
        family: Family?,
        achievementService: AchievementService,
        appState: AppState? = nil
    ) {
        guard let profile else { return }
        if let cache = achievementService.cacheService {
            let familyName = profile.family.recordID.recordName
            let scope: CKDatabase.Scope = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared
            // WHY: freshness-only sole authority — stale cache must re-validate via CloudKit; explicit stale fallback handled at call site (FamilyService-style).
            let profileCount = cache.fetchProfileAchievements(profileRecordName: profile.id.recordName, family: familyName).count
            let profileAuthoritative = cache.isCacheAuthoritative(familyRecordName: familyName, type: .profileAchievement, scope: scope, cachedCount: profileCount)
            let achievementAuthoritative = family.map { fam in
                let count = cache.fetchAchievements(family: fam.id.recordName).count
                return cache.isCacheAuthoritative(familyRecordName: fam.id.recordName, type: .achievement, scope: scope, cachedCount: count)
            } ?? true
            if profileAuthoritative, achievementAuthoritative {
                return
            }
        }
        Task {
            do {
                _ = try await achievementService.fetchEarned(profile: profile)
            } catch {
                let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "ProfileView")
                logger.debug("ProfileView: failed to fetch earned achievements for profile '\(profile.id.recordName, privacy: .private)': \(error, privacy: .private)")
            }
        }
        if let family {
            Task {
                do {
                    _ = try await achievementService.fetchAllDefinitions(family: family)
                } catch {
                    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "ProfileView")
                    logger.debug("ProfileView: failed to fetch achievement definitions for family '\(family.id.recordName, privacy: .private)': \(error, privacy: .private)")
                }
            }
        }
    }
}
