//
//  SettingsRosterHostView.swift
//  LootList
//
//  Created by Ben Mackin on 9/01/26.
//

import os
import SwiftData
import SwiftUI

struct SettingsRosterHostView: View {
    let familyRecordName: String?
    @Environment(AppState.self) private var appState
    @Environment(FamilyService.self) private var familyService
    @Environment(QuestService.self) private var questService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService
    @Environment(AppSyncCoordinator.self) private var appSyncCoordinator
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?
    @State private var viewModel: FamilyDashboardViewModel?
    @State private var heroToEdit: ProfileCache?
    @State private var showRoleTransferConfirm: ProfileCache?
    @State private var isRoleTransferConfirmPresented: Bool = false
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

    init(familyRecordName: String? = nil) {
        self.familyRecordName = familyRecordName
        let targetFamily = familyRecordName ?? ""
        FamilyScopeValidator.assertNonEmpty(targetFamily: targetFamily, viewName: "SettingsRosterHostView")
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

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let vm = viewModel {
                    GuildRosterSectionView(
                        viewModel: vm,
                        onRebuild: { rebuildViewModel() },
                        heroToEdit: $heroToEdit,
                        showRoleTransferConfirm: $showRoleTransferConfirm,
                        isRoleTransferConfirmPresented: $isRoleTransferConfirmPresented
                    )
                } else {
                    ProgressView("Loading roster…")
                        .padding(.top, 40)
                }
            }
            .padding(.vertical, 14)
        }
        .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
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
        .onChange(of: cachedProfiles) { _, _ in
            rebuildViewModel()
            Task { await viewModel?.refreshInvitations() }
        }
        .onChange(of: cachedQuests) { _, _ in rebuildViewModel() }
        .onChange(of: cachedCompletions) { _, _ in rebuildViewModel() }
        .onChange(of: cachedLedgers) { _, _ in rebuildViewModel() }
        .onChange(of: cachedAllowancePeriods) { _, _ in rebuildViewModel() }
        .onChange(of: cachedAchievements) { _, _ in rebuildViewModel() }
        .onChange(of: cachedProfileAchievements) { _, _ in rebuildViewModel() }
        .onChange(of: cachedGoals) { _, _ in rebuildViewModel() }
        .onChange(of: cachedGemLedgers) { _, _ in rebuildViewModel() }
        .onChange(of: cachedRewardEvents) { _, _ in rebuildViewModel() }
        .sheet(item: $heroToEdit) { hero in
            HeroSettingsView(hero: hero)
                .onDisappear {
                    Task { await viewModel?.refresh() }
                }
        }
        .alert("Transfer Guild Master Role?", isPresented: $isRoleTransferConfirmPresented) {
            Button("Transfer Ownership", role: .destructive) {
                if let target = showRoleTransferConfirm {
                    Task { await confirmTransferGuildMaster(to: target) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(showRoleTransferConfirm?.displayName ?? "member") will become the Guild Master. You will become a Ranger.")
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
            // WHY log privately: role transfer failure contains membership context.
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "SettingsRosterHost").error("Failed to transfer Guild Master: \(error, privacy: .private)")
        }
    }
}
