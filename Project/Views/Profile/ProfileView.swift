//
//  ProfileView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
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

    @Environment(FamilyService.self) private var familyService

    @Environment(QuestService.self) private var questService

    @Environment(AchievementService.self) private var achievementService

    @Query private var cachedAchievements: [AchievementCache]
    @Query private var cachedProfileAchievements: [ProfileAchievementCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedProfiles: [ProfileCache]

    @State private var showingEditName: Bool = false

    @State private var showingEditAvatar: Bool = false

    @State private var draftName: String = ""

    @State private var showingSignOutConfirm: Bool = false

    @State private var viewModel = ProfileViewModel()

    /// Family record name used to push the family filter down to SwiftData.
    /// When `nil` (no family loaded) the queries return zero rows, which is
    /// the correct behavior — there is no family to scope to.
    private let familyRecordName: String?

    init(avatarService: AvatarService,
         xpService: XPService,
         notificationService: NotificationService,
         familyRecordName: String? = nil)
    {
        self.avatarService = avatarService
        self.xpService = xpService
        self.notificationService = notificationService
        self.familyRecordName = familyRecordName

        // Filter queries by family at the SwiftData store layer. When familyRecordName is nil,
        // scope to an empty string ("") so zero rows are returned rather than fetching unscoped across all families.
        let targetFamily = familyRecordName ?? ""
        let achievementFilter = #Predicate<AchievementCache> { $0.familyRecordName == targetFamily }
        let profileAchievementFilter = #Predicate<ProfileAchievementCache> { $0.familyRecordName == targetFamily }
        let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily }
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily }
        let profileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }
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
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let profile = appState.currentProfile {
                        characterCard(profile: profile)
                        actionsSection(profile: profile)
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
                    appState.signOut()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your local session will end and you'll return to the Welcome screen. Your Guild data stays synced in iCloud.")
            }
            .sheet(isPresented: $showingEditName) {
                if let profile = appState.currentProfile, profile.role == .hero {
                    editNameSheet(profile: profile)
                }
            }
            .sheet(isPresented: $showingEditAvatar) {
                if let profile = appState.currentProfile {
                    EditAvatarSheet(profile: profile)
                }
            }
            .task {
                recomputeCharacterFromCache()
                viewModel.refreshFreshness(
                    profile: appState.currentProfile,
                    family: appState.family,
                    achievementService: achievementService
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
            zoneID: questService.cloudKitReference.resolvedZoneID
        )
    }

    @ViewBuilder
    private func characterCard(profile: Profile) -> some View {
        let spec = avatarService.renderSpec(for: profile)
        let progress = xpService.levelProgress(profile: profile)

        VStack(spacing: 14) {
            AvatarView(spec: spec, size: .large, showsNameAndTitle: false)

            nameBlock(profile: profile, spec: spec)

            levelBadge(profile: profile, spec: spec)

            xpBlock(profile: profile, progress: progress)

            HStack(spacing: 12) {
                Button {
                    showingEditAvatar = true
                } label: {
                    Label("Change Avatar", systemImage: "photo.badge.plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Color.gold)
                .accessibilityIdentifier("profile.changeAvatarButton")

                if profile.role == .hero {
                    Button {
                        draftName = profile.displayName
                        showingEditName = true
                    } label: {
                        Label("Rename", systemImage: "pencil.line")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.gold)
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
                        Color.purple.opacity(0.35),
                        Color.blue.opacity(0.30),
                        Color.indigo.opacity(0.50)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color.gold.opacity(0.20), .clear],
                    center: .center,
                    startRadius: 0, endRadius: 0.85
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.gold.opacity(0.45), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private func nameBlock(profile: Profile, spec: AvatarRenderSpec) -> some View {
        VStack(spacing: 4) {
            Text(profile.displayName)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(spec.levelTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.gold)
            Text("\(profile.effectiveClassDisplay) • \(profile.role.displayName)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func levelBadge(profile: Profile, spec _: AvatarRenderSpec) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "number")
                .font(.caption.weight(.bold))
            Text("\(profile.level)")
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
                    Capsule().strokeBorder(Color.gold.opacity(0.70), lineWidth: 1)
                )
        )
    }

    private func xpBlock(profile _: Profile, progress: LevelProgress) -> some View {
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
                tint: Color.gold,
                height: 10
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
    }

    private func actionsSection(profile: Profile) -> some View {
        VStack(spacing: 0) {
            NavigationLink {
                CharacterSheetView(
                    profile: profile,
                    avatarService: avatarService,
                    xpService: xpService,
                    streak: viewModel.streak,
                    goldBalance: viewModel.goldBalance,
                    earnedAchievements: viewModel.earnedAchievements,
                    onSaveDisplayName: { newName in
                        guard profile.role == .hero,
                              var updated = appState.currentProfile else { return }
                        updated.displayName = newName
                        appState.currentProfile = updated
                        Task {
                            do {
                                try await familyService.updateProfileDisplayName(profile: updated, newName: newName)
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

            Divider().padding(.leading, 56)

            NavigationLink {
                if let family = appState.family {
                    NotificationSettingsView(
                        notificationService: notificationService,
                        profile: profile,
                        family: family
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
                    subtitle: "Return to the Welcome screen",
                    tint: .red
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
            aboutRow(label: "Loot List", value: "Family chore tracker · RPG mode")
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

    private func editNameSheet(profile _: Profile) -> some View {
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
                        if var updated = appState.currentProfile {
                            updated.displayName = trimmed
                            appState.currentProfile = updated
                            Task {
                                do {
                                    try await familyService.updateProfileDisplayName(profile: updated, newName: trimmed)
                                } catch {
                                    toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                                }
                            }
                        }
                        showingEditName = false
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
    var goldBalance: Double?
    var earnedAchievements: [Achievement] = []

    func reset() {
        streak = nil
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
        zoneID: CKRecordZone.ID
    ) {
        guard let profile else {
            reset()
            return
        }
        let profileName = profile.id.recordName

        let heroCompletions = completions.filter { $0.completerRecordName == profileName }
        streak = StreakCalculator.computeStreak(from: heroCompletions)

        // Wallet balance is sourced exclusively from the ledger: quest earnings
        // are minted as `source == "quest"` ledger entries by
        // `TreasuryService.mintPayoutLedgerEntry` / `mintRealTimeLedgerEntry`,
        // so summing them again from completion logs would double-count.
        // Mirrors `TreasuryViewModel.rebuildLists` (ledger-sum-only pattern).
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
        achievementService: AchievementService
    ) {
        guard let profile else { return }
        if let cache = achievementService.cacheService {
            let familyName = profile.family.recordID.recordName
            let profileFresh = cache.isCacheFresh(familyRecordName: familyName, type: .profileAchievement)
            let achievementFresh = family.map { cache.isCacheFresh(familyRecordName: $0.id.recordName, type: .achievement) } ?? true
            if profileFresh, achievementFresh {
                return
            }
        }
        Task { _ = try? await achievementService.fetchEarned(profile: profile) }
        if let family {
            Task { _ = try? await achievementService.fetchAllDefinitions(family: family) }
        }
    }
}

struct EditAvatarSheet: View {
    let profile: Profile
    @Environment(ToastManager.self) private var toastManager
    @Environment(AppState.self) private var appState
    @Environment(FamilyService.self) private var familyService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedClass: AvatarClass?
    @State private var selectedPresetID: String?
    @State private var customData: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Custom Device Photo") {
                    HStack(spacing: 16) {
                        if let customData, let uiImage = UIImage(data: customData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 50, height: 50)
                                .clipShape(Circle())
                        } else {
                            Circle()
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 50, height: 50)
                                .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
                        }

                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Text("Choose Photo")
                        }

                        if customData != nil {
                            Button("Remove Photo", role: .destructive) {
                                customData = nil
                                photoItem = nil
                            }
                        }
                    }
                }

                Section("RPG Class & Look") {
                    Picker("RPG Class", selection: $selectedClass) {
                        Text("None (Generic)").tag(AvatarClass?.none)
                        ForEach(AvatarClass.allCases, id: \.self) { cls in
                            Text(cls.displayName).tag(AvatarClass?.some(cls))
                        }
                    }
                    .onChange(of: selectedClass) { _, newCls in
                        if let newCls {
                            selectedPresetID = AvatarService.defaultPresetID(for: newCls)
                        } else {
                            selectedPresetID = nil
                        }
                    }

                    if let cls = selectedClass {
                        Picker("Avatar Preset", selection: $selectedPresetID) {
                            ForEach(AvatarPreset.presets(for: cls), id: \.self) { preset in
                                Text(preset.displayName).tag(String?.some(preset.id))
                            }
                        }
                    }
                }

                Section {
                    Button("Reset to Generic Avatar", role: .destructive) {
                        selectedClass = nil
                        selectedPresetID = nil
                        customData = nil
                        photoItem = nil
                    }
                }
            }
            .navigationTitle("Edit Avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            do {
                                try await familyService.updateProfileAvatar(
                                    profile: profile,
                                    avatarClass: selectedClass,
                                    avatarPresetID: selectedPresetID,
                                    customAvatarImageData: customData
                                )
                            } catch {
                                toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                            }
                            dismiss()
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .onChange(of: photoItem) { _, newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self) {
                        customData = AvatarService.resizeImageData(data, maxDimension: 400)
                    }
                }
            }
            .onAppear {
                selectedClass = profile.avatarClass
                selectedPresetID = profile.avatarPresetID
                customData = profile.customAvatarImageData
            }
        }
    }
}
