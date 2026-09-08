//
//  ChildHubView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import os
import SwiftData
import SwiftUI

/// Home tab for the child role: balance hero card with bucket tiles, weekly
/// progress ring, today's chores, the active FIFO goal, and a pinned
/// log-a-purchase CTA.
struct ChildHubView: View {
    private static let logger = Logger(category: "ChildHubView")

    @Environment(AppState.self) private var appState
    @Environment(TreasuryService.self) private var treasury
    @Environment(QuestService.self) private var questService
    @Environment(ToastManager.self) private var toastManager: ToastManager?
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?
    @Environment(CacheService.self) private var cacheService: CacheService?

    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedTemplates: [QuestTemplateCache]
    @Query private var cachedGoals: [GoalCache]
    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]
    @Query private var cachedProfiles: [ProfileCache]
    @Query private var currentProfileRows: [ProfileCache]

    @State private var viewModel: ChildHubViewModel?
    @State private var treasuryViewModel: TreasuryViewModel?
    @State private var isShowingLogSpending: Bool = false
    @State private var isShowingSplit: Bool = false
    @State private var submittingQuestIDs: Set<String> = []
    @State private var showCelebration: Bool = false
    @State private var pendingWithdrawal: PendingWithdrawal?

    struct PendingWithdrawal: Identifiable {
        let quest: QuestCache
        let log: QuestCompletionCache
        var id: String {
            quest.recordName
        }
    }

    private let spending: SpendingService
    private let familyRecordName: String?

    private let profileRecordName: String?

    init(spending: SpendingService, familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.spending = spending
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName

        let targetFamily = HubQueryProvider.targetFamily(familyRecordName)
        FamilyScopeValidator.validateOrFault(targetFamily: targetFamily, viewName: "ChildHubView")
        // WHY: fail-closed to "" when profileRecordName is nil; AppState not yet resolved in init.
        let targetProfile = profileRecordName ?? ""
        // WHY shared provider: family+profile pushdown owns the isolation boundary and stable sorts.
        let questFilter = HubQueryProvider.questScopedFilter(family: targetFamily, profile: targetProfile)
        let completionFilter = HubQueryProvider.completionScopedFilter(family: targetFamily, profile: targetProfile)
        // WHY: templates are family-scoped (shared across heroes).
        let templateFilter = HubQueryProvider.templateFilter(family: targetFamily)
        let goalFilter = HubQueryProvider.goalScopedFilter(family: targetFamily, profile: targetProfile)
        let ledgerFilter = HubQueryProvider.ledgerScopedFilter(family: targetFamily, profile: targetProfile)
        let allowanceFilter = HubQueryProvider.allowanceScopedFilter(family: targetFamily, profile: targetProfile)
        let profileFilter = HubQueryProvider.profileFilter(family: targetFamily)
        let currentProfileFilter = HubQueryProvider.currentProfileScopedFilter(family: targetFamily, profile: targetProfile)

        // WHY: stable sort — secondary recordName keeps ForEach stable after CloudKit reorders.
        _cachedQuests = Query(filter: questFilter, sort: HubQueryProvider.questSort())
        _cachedCompletions = Query(filter: completionFilter, sort: HubQueryProvider.completionSort())
        _cachedTemplates = Query(filter: templateFilter, sort: HubQueryProvider.templateSort())
        _cachedGoals = Query(filter: goalFilter, sort: HubQueryProvider.goalSort())
        _cachedLedgers = Query(filter: ledgerFilter, sort: HubQueryProvider.ledgerSort())
        _cachedAllowancePeriods = Query(filter: allowanceFilter, sort: HubQueryProvider.allowanceSort())
        _cachedProfiles = Query(filter: profileFilter, sort: \ProfileCache.displayName)
        _currentProfileRows = Query(filter: currentProfileFilter, sort: \ProfileCache.displayName)
    }

    /// Queried cache row for active hero profile; nil when scope has no synced row (fail-closed rendering).
    private var currentProfileRow: ProfileCache? {
        currentProfileRows.first
    }

    private var targetFamilyForFreshness: String {
        familyRecordName ?? ""
    }

    private var isSyncingPlaceholder: Bool {
        guard currentProfileRow == nil else { return false }
        guard appState.authStatus == .authenticated else { return false }
        guard !targetFamilyForFreshness.isEmpty else { return false }
        let isEmpty = cachedQuests.isEmpty && cachedProfiles.isEmpty && cachedGoals.isEmpty
        guard isEmpty else { return false }
        let isFresh = appState.cacheService?.isCacheFresh(familyRecordName: targetFamilyForFreshness, type: .profile) ?? false
        return !isFresh
    }

    private var isProfileNotFoundPlaceholder: Bool {
        guard currentProfileRow == nil else { return false }
        guard appState.authStatus == .authenticated else { return false }
        guard !targetFamilyForFreshness.isEmpty else { return false }
        return appState.cacheService?.isCacheFresh(familyRecordName: targetFamilyForFreshness, type: .profile) ?? false
    }

    private var staleBannerCount: Int {
        ChildHubViewModel.staleBannerCount(
            profiles: cachedProfiles.count,
            quests: cachedQuests.count,
            goals: cachedGoals.count,
            ledgers: cachedLedgers.count
        )
    }

    private var isBannerSyncing: Bool {
        lifecycleCoordinator?.isSyncing == true
    }

    private var hubDisplayName: String? {
        currentProfileRow?.displayName
    }

    private var recentLedgersSlice: [LedgerEntryCache] {
        ChildHubViewModel.recentLedgers(cachedLedgers)
    }

    @ViewBuilder
    private var profileStaleBanner: some View {
        if !targetFamilyForFreshness.isEmpty {
            let family: String = targetFamilyForFreshness
            let count: Int = staleBannerCount
            let syncing: Bool = isBannerSyncing
            StaleDataBanner(family: family, type: .profile, count: count, isSyncing: syncing)
        }
    }

    @ViewBuilder
    private var hubContent: some View {
        if isSyncingPlaceholder {
            ChildHubSyncingCardView()
        } else if isProfileNotFoundPlaceholder {
            ChildHubProfileNotFoundCardView(onRetry: {
                Task { await lifecycleCoordinator?.performManualSync() }
            })
        } else {
            hubLoadedContent
        }
    }

    @ViewBuilder
    private var hubLoadedContent: some View {
        if let viewModel {
            let name: String? = firstName
            let displayName: String? = hubDisplayName
            let ledgers: [LedgerEntryCache] = recentLedgersSlice
            let streakValue: Int = viewModel.streak
            ChildHubBalanceSection(
                viewModel: viewModel,
                firstName: name,
                displayName: displayName,
                onSplitTapped: { isShowingSplit = true }
            )
            ChildHubCardsView(
                viewModel: viewModel,
                cachedQuests: cachedQuests,
                cachedCompletions: cachedCompletions,
                submittingQuestIDs: submittingQuestIDs,
                familyRecordName: familyRecordName,
                onCompleteQuest: { quest in completeQuest(quest) },
                onWithdraw: handleWithdraw,
                recentLedgers: ledgers,
                streak: streakValue,
                cachedTemplates: cachedTemplates,
                profileRecordName: profileRecordName
            )
        }
    }

    private func handleWithdraw(quest: QuestCache, log: QuestCompletionCache) {
        pendingWithdrawal = PendingWithdrawal(quest: quest, log: log)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystemConstants.Padding.standard) {
                    header
                    profileStaleBanner
                    hubContent
                }
                .maxContentWidth()
                .padding(.horizontal, DesignSystemConstants.Padding.standard)
                .padding(.top, DesignSystemConstants.Padding.small)
                .padding(.bottom, DesignSystemConstants.Padding.large)
            }
            .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                await lifecycleCoordinator?.performManualSync()
            }
            .overlay {
                CelebrationOverlay(isPresented: showCelebration)
            }
            .alert(
                "Unsubmit Quest?",
                isPresented: Binding(
                    get: { pendingWithdrawal != nil },
                    set: {
                        if !$0 {
                            pendingWithdrawal = nil
                        }
                    }
                ),
                presenting: pendingWithdrawal
            ) { target in
                Button("Move Back to To-Do", role: .destructive) {
                    withdrawQuest(target.quest, log: target.log)
                }
                Button("Keep Sent for Review", role: .cancel) {
                    pendingWithdrawal = nil
                }
            } message: { target in
                Text("Move “\(target.quest.questName)” back to your active to-do list?")
            }
            .safeAreaInset(edge: .bottom) {
                logPurchaseBar
                    .padding(.horizontal, DesignSystemConstants.Padding.standard)
                    .padding(.vertical, DesignSystemConstants.Padding.small)
                    .background(Color(DesignSystemConstants.Colors.background))
            }
            .sheet(isPresented: $isShowingLogSpending) {
                if let treasuryViewModel {
                    LogSpendingView(viewModel: treasuryViewModel, familyRecordName: familyRecordName)
                }
            }
            .sheet(isPresented: $isShowingSplit) {
                SavingsSplitView(
                    familyRecordName: familyRecordName,
                    profileRecordName: profileRecordName ?? appState.currentProfile?.id.recordName
                )
            }
            .task {
                ensureViewModels()
            }
            .onChange(of: cachedQuests) { _, _ in rebuild() }
            .onChange(of: cachedCompletions) { _, _ in rebuild() }
            .onChange(of: cachedTemplates) { _, _ in rebuild() }
            .onChange(of: cachedGoals) { _, _ in rebuild() }
            .onChange(of: cachedLedgers) { _, _ in rebuild() }
            .onChange(of: cachedAllowancePeriods) { _, _ in rebuild() }
            .onChange(of: cachedProfiles) { _, _ in rebuild() }
            .onChange(of: currentProfileRows) { _, _ in rebuild() }
        }
        // WHY: view identity tracks profileRecordName so @Query predicates (init-captured) are recreated on profile switch; defensive filter in rebuild() is secondary guard.
        .id(profileRecordName)
    }

    // MARK: - Header (focused section)

    private var header: some View {
        ChildHubHeaderView(
            currentProfileRow: currentProfileRow,
            firstName: firstName,
            isSyncingPlaceholder: isSyncingPlaceholder,
            isProfileNotFoundPlaceholder: isProfileNotFoundPlaceholder,
            onRetry: {
                Task { await lifecycleCoordinator?.performManualSync() }
            }
        )
    }

    private var firstName: String? {
        ChildHubViewModel.firstName(displayName: currentProfileRow?.displayName)
    }

    // MARK: - Log-a-Purchase CTA (focused section)

    private var logPurchaseBar: some View {
        ChildHubActionBarView(onLogPurchase: { isShowingLogSpending = true })
    }

    // MARK: - Rebuild

    private func ensureViewModels() {
        let vm = ViewLifecycle.ensure(&viewModel, factory: {
            ChildHubViewModel(
                appState: appState,
                cacheService: cacheService ?? appState.cacheService
            )
        })
        let tvm = ViewLifecycle.ensure(&treasuryViewModel, factory: {
            TreasuryViewModel(
                treasury: treasury,
                spending: spending,
                appState: appState
            )
        })
        rebuild(vm, tvm)
    }

    private func rebuild(_ vm: ChildHubViewModel? = nil, _ tvm: TreasuryViewModel? = nil) {
        appState.updateCurrentProfileFromCache()
        guard let currentName = appState.currentProfile?.id.recordName else { return }

        // WHY: predicate is primary profile scope; secondary in-memory guard prevents cross-profile leak when view identity is stale (profile switches without recreation).
        let quests = cachedQuests.filter { $0.assigneeRecordName == currentName }
        let logs = cachedCompletions.filter { $0.completerRecordName == currentName }
        let ledgers = cachedLedgers.filter { $0.profileRecordName == currentName }
        let periods = cachedAllowancePeriods.filter { $0.profileRecordName == currentName }

        (vm ?? viewModel)?.rebuild(
            quests: quests,
            logs: logs,
            templates: cachedTemplates,
            goals: cachedGoals
        )

        if let treasury = tvm ?? treasuryViewModel {
            treasury.rebuildLists(
                logs: logs,
                ledgers: ledgers,
                quests: quests,
                allowancePeriods: periods,
                scope: .thisWeek,
                templates: cachedTemplates
            )
        }
    }

    // MARK: - Quest Actions

    private func withdrawQuest(_ quest: QuestCache, log: QuestCompletionCache) {
        let qID = quest.recordName
        guard !submittingQuestIDs.contains(qID) else { return }
        submittingQuestIDs.insert(qID)
        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: log)
        // WHY snapshot: @Model rows cannot cross isolation; Sendable struct rides the Task.
        let logSnapshot = log.toQuestCompletion(zoneID: zoneID)
        guard let profile = appState.currentProfile else {
            submittingQuestIDs.remove(qID)
            return
        }
        Task { @MainActor @Sendable [logSnapshot, profile, qID] in
            defer { submittingQuestIDs.remove(qID) }
            do {
                try await questService.withdrawCompletion(questLog: logSnapshot, by: profile)
                HapticsService.lightImpact()
            } catch {
                Self.logger.error("Failed to unsubmit quest: \(error, privacy: .private)")
            }
        }
    }

    private func completeQuest(_ quest: QuestCache) {
        let qID = quest.recordName
        guard !submittingQuestIDs.contains(qID) else { return }
        submittingQuestIDs.insert(qID)
        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: quest)
        // WHY snapshot: @Model rows cannot cross isolation; Sendable structs ride the Task.
        let questSnapshot = quest.toQuest(zoneID: zoneID)
        let priorApproved = cachedCompletions.filter { $0.questRecordName == qID && $0.isApproved }.count
        let templatesByID = SpecificDaysHelper.templatesByID(cachedTemplates)
        // WHY day count wins: legacy rows keep stale targetCount after template gains days.
        let effectiveTarget = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
        guard let profile = appState.currentProfile else {
            submittingQuestIDs.remove(qID)
            return
        }
        let celebration = $showCelebration
        Task { @MainActor @Sendable [questSnapshot, profile, priorApproved, effectiveTarget, qID, celebration] in
            defer { submittingQuestIDs.remove(qID) }
            do {
                let completion = try await questService.markComplete(
                    quest: questSnapshot,
                    by: profile
                )
                if completion.verificationStatus == .autoApproved {
                    let isFinal = GoldCalculation.isFullyCompleted(
                        quest: questSnapshot,
                        approvedCount: priorApproved + 1,
                        effectiveTarget: effectiveTarget
                    )
                    if isFinal {
                        HapticsService.success()
                        celebration.wrappedValue = true
                        Task { @MainActor @Sendable [celebration] in
                            do {
                                try await Task.sleep(
                                    for: .seconds(DesignSystemConstants.Celebration.confettiLifetime)
                                )
                            } catch {
                                Self.logger.debug("Celebration dismiss sleep interrupted: \(error, privacy: .private)")
                            }
                            celebration.wrappedValue = false
                        }
                    } else {
                        HapticsService.lightImpact()
                        toastManager?.show(
                            message: "Part \(priorApproved + 1) of \(effectiveTarget) complete! 🎯",
                            type: .success
                        )
                    }
                } else if completion.verificationStatus == .pending {
                    HapticsService.lightImpact()
                    toastManager?.show(
                        message: "Quest sent to Parent for review! ⏳",
                        type: .info
                    )
                }
            } catch {
                Self.logger.error("Failed to mark quest complete: \(error, privacy: .private)")
            }
        }
    }
}
