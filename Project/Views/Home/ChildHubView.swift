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
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "ChildHubView")

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

        let targetFamily = familyRecordName ?? ""
        FamilyScopeValidator.validateOrFault(targetFamily: targetFamily, viewName: "ChildHubView")
        // WHY: fail-closed to "" when profileRecordName is nil; AppState not yet resolved in init.
        let targetProfile = profileRecordName ?? ""
        // WHY: predicate pushdown — filter by family+profile at store; fail-closed to 0 rows when empty.
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.assigneeRecordName == targetProfile && $0.isActive == true }
        let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily && $0.completerRecordName == targetProfile }
        // WHY: templates are family-scoped (shared across heroes).
        let templateFilter = #Predicate<QuestTemplateCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let goalFilter = #Predicate<GoalCache> { $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile }
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile }
        let allowanceFilter = #Predicate<AllowancePeriodCache> { $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile }
        let profileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }
        let currentProfileFilter = #Predicate<ProfileCache> {
            $0.recordName == targetProfile && $0.familyRecordName == targetFamily
        }

        // WHY: stable sort — secondary recordName keeps ForEach stable after CloudKit reorders.
        _cachedQuests = Query(filter: questFilter, sort: [SortDescriptor(\QuestCache.weekOf, order: .reverse), SortDescriptor(\QuestCache.recordName)])
        _cachedCompletions = Query(
            filter: completionFilter,
            sort: [SortDescriptor(\QuestCompletionCache.completedDate, order: .reverse), SortDescriptor(\QuestCompletionCache.recordName)]
        )
        _cachedTemplates = Query(filter: templateFilter, sort: [SortDescriptor(\QuestTemplateCache.name), SortDescriptor(\QuestTemplateCache.recordName)])
        _cachedGoals = Query(filter: goalFilter, sort: [SortDescriptor(\GoalCache.createdAt), SortDescriptor(\GoalCache.recordName)])
        _cachedLedgers = Query(filter: ledgerFilter, sort: [SortDescriptor(\LedgerEntryCache.date, order: .reverse), SortDescriptor(\LedgerEntryCache.recordName)])
        _cachedAllowancePeriods = Query(
            filter: allowanceFilter,
            sort: [SortDescriptor(\AllowancePeriodCache.weekOf, order: .reverse), SortDescriptor(\AllowancePeriodCache.recordName)]
        )
        _cachedProfiles = Query(filter: profileFilter, sort: \ProfileCache.displayName)
        _currentProfileRows = Query(
            filter: currentProfileFilter,
            sort: \ProfileCache.displayName
        )
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
        let profiles: Int = cachedProfiles.count
        let quests: Int = cachedQuests.count
        let goals: Int = cachedGoals.count
        let ledgers: Int = cachedLedgers.count
        return profiles + quests + goals + ledgers
    }

    private var isBannerSyncing: Bool {
        lifecycleCoordinator?.isSyncing == true
    }

    private var hubDisplayName: String? {
        currentProfileRow?.displayName
    }

    private var recentLedgersSlice: [LedgerEntryCache] {
        Array(cachedLedgers.prefix(7))
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
            syncingBalanceCard
        } else if isProfileNotFoundPlaceholder {
            profileNotFoundCard
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
                streak: streakValue
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

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if isSyncingPlaceholder {
            VStack(spacing: 8) {
                ProgressView()
                Text("Syncing your family...")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Syncing your family")
            .accessibilityIdentifier("hub.syncingPlaceholder")
        } else if isProfileNotFoundPlaceholder {
            VStack(spacing: 8) {
                Text("Profile not found — pull to refresh")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await lifecycleCoordinator?.performManualSync() }
                } label: {
                    Text("Retry")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry sync")
                .accessibilityIdentifier("hub.retryButton")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Profile not found — pull to refresh")
            .accessibilityIdentifier("hub.profileNotFoundPlaceholder")
        } else if let row = currentProfileRow {
            HStack(spacing: DesignSystemConstants.Padding.medium) {
                Text(row.avatarEmoji ?? "🦸")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.15)))
                    .overlay(Circle().strokeBorder(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.3), lineWidth: 1))

                if let name = firstName {
                    Text("\(name)'s Hub")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else {
                    Text("\(row.displayName)'s Hub")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(firstName ?? row.displayName)'s Hub")
            .accessibilityIdentifier("hub.headerTitle")
        } else {
            HStack(spacing: DesignSystemConstants.Padding.medium) {
                Text("🦸")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.15)))
                    .overlay(Circle().strokeBorder(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.3), lineWidth: 1))

                Text("Your Hub")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Your Hub")
            .accessibilityIdentifier("hub.headerTitle")
        }
    }

    private var firstName: String? {
        guard let name = currentProfileRow?.displayName, !name.isEmpty else { return nil }
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    private var syncingBalanceCard: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Syncing your family...")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(DesignSystemConstants.Padding.large)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Syncing your family")
        .accessibilityIdentifier("hub.syncingBalanceCard")
    }

    private var profileNotFoundCard: some View {
        VStack(spacing: 16) {
            Text("Profile not found — pull to refresh")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await lifecycleCoordinator?.performManualSync() }
            } label: {
                Text("Retry")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry sync")
            .accessibilityIdentifier("hub.retryButtonCard")
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(DesignSystemConstants.Padding.large)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Profile not found — pull to refresh")
        .accessibilityIdentifier("hub.profileNotFoundCard")
    }

    // MARK: - Log-a-Purchase CTA

    private var logPurchaseBar: some View {
        Button {
            HapticsService.lightImpact()
            isShowingLogSpending = true
        } label: {
            Label("Log a Purchase / Spend", systemImage: "cart.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.button, style: .continuous)
                        .fill(Color(DesignSystemConstants.Colors.primaryGreen))
                )
        }
        .accessibilityHint("Opens the spending log form")
        .accessibilityIdentifier("hub.logPurchaseButton")
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
                scope: .thisWeek
            )
        }
    }

    // MARK: - Quest Actions

    private func withdrawQuest(_ quest: QuestCache, log: QuestCompletionCache) {
        let qID = quest.recordName
        guard !submittingQuestIDs.contains(qID) else { return }
        submittingQuestIDs.insert(qID)

        Task { @MainActor in
            defer { submittingQuestIDs.remove(qID) }
            guard let profile = appState.currentProfile else { return }
            do {
                try await questService.withdrawCompletion(questLog: log, by: profile)
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

        Task { @MainActor in
            defer { submittingQuestIDs.remove(qID) }
            guard let profile = appState.currentProfile else { return }

            let zoneID = appState.resolvedFamilyZoneID()
            let domain = quest.toQuest(zoneID: zoneID)

            let priorApproved = cachedCompletions.filter { $0.questRecordName == qID && $0.isApproved }.count

            do {
                let completion = try await questService.markComplete(
                    quest: domain,
                    by: profile
                )
                QuestCompletionHelper.handleCompletionResult(
                    completion,
                    quest: quest,
                    priorApproved: priorApproved,
                    toastManager: toastManager,
                    showCelebration: $showCelebration
                )
            } catch {
                Self.logger.error("Failed to mark quest complete: \(error, privacy: .private)")
            }
        }
    }
}
