//
//  GuildSettingsView.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import os
import SwiftData
import SwiftUI

struct GuildSettingsView: View {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "GuildSettings")

    @Environment(ToastManager.self) private var toastManager
    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService
    @Environment(FamilyService.self) private var familyService
    @Environment(AppSyncCoordinator.self) private var appSyncCoordinator
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?

    @State private var viewModel: FamilyDashboardViewModel?

    @Query private var cachedProfiles: [ProfileCache]
    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]
    @Query private var cachedAchievements: [AchievementCache]
    @Query private var cachedProfileAchievements: [ProfileAchievementCache]
    @Query private var cachedGoals: [GoalCache]
    @Query private var cachedGemLedgers: [GemLedgerCache]
    @Query private var cachedRewardEvents: [RewardEventCache]

    @State private var draftFamilyName: String = ""
    @State private var isEditingFamilyName: Bool = false

    @State private var showRolePicker: Bool = false
    @State private var sharePresentation: CloudSharePresentation?
    @State private var heroToEdit: ProfileCache?

    @State private var showRoleTransferConfirm: ProfileCache?
    @State private var isRoleTransferConfirmPresented: Bool = false
    @State private var isPayoutPolicyExpanded: Bool = false
    @State private var revokeError: String?
    @State private var isSigningOut: Bool = false

    private let familyRecordName: String?

    init(familyRecordName: String? = nil) {
        self.familyRecordName = familyRecordName
        let targetFamily = familyRecordName ?? ""
        FamilyScopeValidator.assertNonEmpty(targetFamily: targetFamily, viewName: "GuildSettingsView")
        let profileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily }
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
        let allowanceFilter = #Predicate<AllowancePeriodCache> { $0.familyRecordName == targetFamily }
        let achievementFilter = #Predicate<AchievementCache> { $0.familyRecordName == targetFamily }
        let profileAchievementFilter = #Predicate<ProfileAchievementCache> { $0.familyRecordName == targetFamily }
        let goalFilter = #Predicate<GoalCache> { $0.familyRecordName == targetFamily }
        let gemLedgerFilter = #Predicate<GemLedgerCache> { $0.familyRecordName == targetFamily }
        let rewardEventFilter = #Predicate<RewardEventCache> { $0.familyRecordName == targetFamily }

        // WHY stable sorts: all caches feed ForEach(id: \.recordName); secondary recordName tie-breaker keeps ordering deterministic across CloudKit merge reorders.
        _cachedProfiles = Query(filter: profileFilter, sort: [SortDescriptor(\ProfileCache.displayName), SortDescriptor(\ProfileCache.recordName)])
        _cachedQuests = Query(filter: questFilter, sort: [SortDescriptor(\QuestCache.weekOf, order: .reverse), SortDescriptor(\QuestCache.recordName)])
        _cachedCompletions = Query(
            filter: completionFilter,
            sort: [SortDescriptor(\QuestCompletionCache.completedDate, order: .reverse), SortDescriptor(\QuestCompletionCache.recordName)]
        )
        _cachedLedgers = Query(filter: ledgerFilter, sort: [SortDescriptor(\LedgerEntryCache.date, order: .reverse), SortDescriptor(\LedgerEntryCache.recordName)])
        _cachedAllowancePeriods = Query(
            filter: allowanceFilter,
            sort: [SortDescriptor(\AllowancePeriodCache.weekOf, order: .reverse), SortDescriptor(\AllowancePeriodCache.recordName)]
        )
        _cachedAchievements = Query(filter: achievementFilter, sort: [SortDescriptor(\AchievementCache.name), SortDescriptor(\AchievementCache.recordName)])
        _cachedProfileAchievements = Query(
            filter: profileAchievementFilter,
            sort: [SortDescriptor(\ProfileAchievementCache.earnedDate, order: .reverse), SortDescriptor(\ProfileAchievementCache.recordName)]
        )
        _cachedGoals = Query(filter: goalFilter, sort: [SortDescriptor(\GoalCache.createdAt), SortDescriptor(\GoalCache.recordName)])
        _cachedGemLedgers = Query(filter: gemLedgerFilter, sort: [SortDescriptor(\GemLedgerCache.createdAt, order: .reverse), SortDescriptor(\GemLedgerCache.recordName)])
        _cachedRewardEvents = Query(filter: rewardEventFilter, sort: [SortDescriptor(\RewardEventCache.timestamp, order: .reverse), SortDescriptor(\RewardEventCache.recordName)])
    }

    private var isRevokeAlertPresented: Binding<Bool> {
        Binding(
            get: { revokeError != nil },
            set: { isPresented in
                if !isPresented {
                    revokeError = nil
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            scrollViewContent
                .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
                .navigationTitle("Guild Settings")
                .navigationBarTitleDisplayMode(.large)
                .refreshable {
                    await lifecycleCoordinator?.performManualSync()
                    await viewModel?.refresh()
                    rebuildViewModel()
                    await viewModel?.refreshInvitations()
                }
                .task {
                    ensureViewModel()
                    viewModel?.subscribeToSyncEvents(appSyncCoordinator)
                    await lifecycleCoordinator?.performManualSync()
                    await viewModel?.refresh()
                    await viewModel?.refreshInvitations()
                }
                .onDisappear {
                    viewModel?.unsubscribeFromSyncEvents(appSyncCoordinator)
                }
                .modifier(CacheObserversModifier(
                    cachedProfiles: cachedProfiles,
                    cachedQuests: cachedQuests,
                    cachedCompletions: cachedCompletions,
                    cachedLedgers: cachedLedgers,
                    cachedAllowancePeriods: cachedAllowancePeriods,
                    cachedAchievements: cachedAchievements,
                    cachedProfileAchievements: cachedProfileAchievements,
                    cachedGoals: cachedGoals,
                    cachedGemLedgers: cachedGemLedgers,
                    cachedRewardEvents: cachedRewardEvents,
                    onProfilesChanged: {
                        rebuildViewModel()
                        Task { await viewModel?.refreshInvitations() }
                    },
                    onCacheChanged: {
                        rebuildViewModel()
                    }
                ))
                .sheet(isPresented: $showRolePicker) {
                    InviteRolePickerView { role in
                        await presentInviteShare(for: role)
                    }
                }
                .sheet(item: $sharePresentation) { presentation in
                    CloudSharingControllerWrapper(presentation: presentation)
                }
                .sheet(item: $heroToEdit) { hero in
                    HeroSettingsView(hero: hero)
                        .onDisappear {
                            Task { await viewModel?.refresh() }
                        }
                }
                .onChange(of: sharePresentation?.id) { _, newID in
                    if newID == nil, sharePresentation == nil {
                        Task { await viewModel?.refreshInvitations() }
                    }
                }
                .onChange(of: viewModel?.loadError) { _, newError in
                    if let error = newError {
                        toastManager.show(message: error, type: .error)
                        revokeError = error
                    }
                }
                .alert("Revoke Failed",
                       isPresented: isRevokeAlertPresented)
                {
                    Button("OK", role: .cancel) { revokeError = nil }
                } message: {
                    Text(revokeError ?? "Could not revoke access. Please try again.")
                }
                .alert("Transfer Guild Master Role?",
                       isPresented: $isRoleTransferConfirmPresented)
                {
                    Button("Transfer Ownership", role: .destructive) {
                        if let target = showRoleTransferConfirm {
                            Task { await confirmTransferGuildMaster(to: target) }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("\(showRoleTransferConfirm?.displayName ?? "member") will become the Guild Master. You will become a Ranger.")
                }
                .overlay {
                    if isSigningOut {
                        ProgressView("Signing out…")
                            .padding(24)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
        }
    }

    private var scrollViewContent: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let vm = viewModel {
                    loadedContent(vm: vm)
                } else {
                    loadingPlaceholder
                }
            }
            .padding(.vertical, 14)
        }
    }

    private func ensureViewModel() {
        ViewLifecycle.ensureAndRebuild(&viewModel, factory: {
            FamilyDashboardViewModel(
                questService: questService,
                treasury: treasury,
                achievementService: achievementService,
                familyService: familyService,
                appState: appState
            )
        }, rebuild: { vm in rebuildViewModel(vm) })
    }

    private func rebuildViewModel(_ vm: FamilyDashboardViewModel? = nil) {
        guard let targetVM = vm ?? viewModel else { return }
        targetVM.rebuildLists(
            profiles: cachedProfiles,
            quests: cachedQuests,
            logs: cachedCompletions,
            ledgers: cachedLedgers,
            allowancePeriods: cachedAllowancePeriods,
            profileAchievements: cachedProfileAchievements,
            achievements: cachedAchievements
        )
    }

    @ViewBuilder
    private func loadedContent(vm: FamilyDashboardViewModel) -> some View {
        familyHeaderSection
        GuildRosterSectionView(
            viewModel: vm,
            onRebuild: { rebuildViewModel() },
            heroToEdit: $heroToEdit,
            showRoleTransferConfirm: $showRoleTransferConfirm,
            isRoleTransferConfirmPresented: $isRoleTransferConfirmPresented
        )
        if appState.currentProfile?.role == .guildMaster {
            GuildPayoutDefaultsSectionView(isPayoutPolicyExpanded: $isPayoutPolicyExpanded)
        }
        GuildDangerZoneSectionView(isSigningOut: $isSigningOut)
    }

    private var familyHeaderSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "house.fill")
                    .foregroundStyle(.tint)
                if isEditingFamilyName {
                    TextField("Family name", text: $draftFamilyName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("settings.familyNameField")
                } else {
                    Text(appState.family?.name ?? "—")
                        .font(.body.weight(.semibold))
                }
                Spacer()
                if appState.currentProfile?.role == .guildMaster {
                    if isEditingFamilyName {
                        Button("Save") {
                            Task { await saveFamilyName() }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("settings.familyNameSave")
                    } else {
                        Button("Edit") {
                            draftFamilyName = appState.family?.name ?? ""
                            isEditingFamilyName = true
                        }
                        .accessibilityIdentifier("settings.familyNameEdit")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if appState.currentProfile?.role == .guildMaster {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Guild Invitations")
                            .font(.subheadline.weight(.semibold))
                        Text("Invite a Hero or Co-Parent to your guild")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        showRolePicker = true
                    } label: {
                        Label("Invite Members", systemImage: "person.badge.plus")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings.inviteMembers")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .padding(.horizontal)
    }

    @MainActor
    private func saveFamilyName() async {
        guard let family = appState.family else { return }
        let trimmed = draftFamilyName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            isEditingFamilyName = false
            return
        }
        do {
            try await familyService.updateFamilyName(family: family, newName: trimmed)
            isEditingFamilyName = false
        } catch {
            logger.error("Failed to rename family: \(error, privacy: .private)")
            toastManager.show(message: "Could not rename the family. Please try again.", type: .error)
        }
    }

    @MainActor
    private func presentInviteShare(for role: UserRole) async {
        guard let presentation = await viewModel?.prepareInviteShare(for: role) else {
            toastManager.show(message: "Could not create an invitation. Please try again.", type: .error)
            return
        }
        guard presentation.shareURL != nil else {
            toastManager.show(message: "Could not generate a share link for this invitation. Please try again.", type: .error)
            return
        }
        sharePresentation = presentation
    }

    @MainActor
    private func confirmTransferGuildMaster(to newOwner: ProfileCache) async {
        guard let current = appState.currentProfile else { return }
        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: newOwner)
        do {
            try await familyService.updateMemberRole(profile: newOwner.toProfile(zoneID: zoneID), newRole: .guildMaster)
            try await familyService.updateMemberRole(profile: current, newRole: .ranger)
            await viewModel?.refresh()
            showRoleTransferConfirm = nil
        } catch {
            logger.error("Failed to transfer Guild Master: \(error, privacy: .private)")
            toastManager.show(message: "Could not transfer Guild Master. Please try again.", type: .error)
        }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "gear")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
                .padding(.top, 120)
            Text("Loading guild settings…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - CacheObserversModifier

private struct CacheObserversModifier: ViewModifier {
    let cachedProfiles: [ProfileCache]
    let cachedQuests: [QuestCache]
    let cachedCompletions: [QuestCompletionCache]
    let cachedLedgers: [LedgerEntryCache]
    let cachedAllowancePeriods: [AllowancePeriodCache]
    let cachedAchievements: [AchievementCache]
    let cachedProfileAchievements: [ProfileAchievementCache]
    let cachedGoals: [GoalCache]
    let cachedGemLedgers: [GemLedgerCache]
    let cachedRewardEvents: [RewardEventCache]
    let onProfilesChanged: () -> Void
    let onCacheChanged: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: cachedProfiles) { _, _ in onProfilesChanged() }
            .onChange(of: cachedQuests) { _, _ in onCacheChanged() }
            .onChange(of: cachedCompletions) { _, _ in onCacheChanged() }
            .onChange(of: cachedLedgers) { _, _ in onCacheChanged() }
            .onChange(of: cachedAllowancePeriods) { _, _ in onCacheChanged() }
            .onChange(of: cachedAchievements) { _, _ in onCacheChanged() }
            .onChange(of: cachedProfileAchievements) { _, _ in onCacheChanged() }
            .onChange(of: cachedGoals) { _, _ in onCacheChanged() }
            .onChange(of: cachedGemLedgers) { _, _ in onCacheChanged() }
            .onChange(of: cachedRewardEvents) { _, _ in onCacheChanged() }
    }
}
