//
//  FamilyDashboardView.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import os
import SwiftData
import SwiftUI

struct FamilyDashboardView: View {
    private static let logger = Logger(category: "FamilyDashboardView")
    @Environment(ToastManager.self) private var toastManager
    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(FamilyService.self) private var familyService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService
    @Environment(AppSyncCoordinator.self) private var appSyncCoordinator
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var viewModel: FamilyDashboardViewModel?
    @State private var syncHost: DashboardSyncHost?
    @State private var sharePresentation: CloudSharePresentation?
    @State private var selectedChildRecordName: String?
    @State private var showPendingInspector = false
    @State private var showRolePicker = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    @Query private var cachedProfiles: [ProfileCache]
    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]
    @Query private var cachedAchievements: [AchievementCache]
    @Query private var cachedProfileAchievements: [ProfileAchievementCache]
    @Query private var cachedTemplates: [QuestTemplateCache]
    @Query private var currentProfileRows: [ProfileCache]
    @Query private var cachedFamilies: [FamilyCache]

    /// Family record name used to push the family filter down to SwiftData.
    /// When `nil` (no family loaded) the queries return zero rows, which is
    /// the correct behavior — there is no family to scope to.
    private let spending: SpendingService
    private let familyRecordName: String?
    private let profileRecordName: String?

    init(spending: SpendingService, familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.spending = spending
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName

        let targetFamily = familyRecordName ?? ""
        FamilyScopeValidator.validateOrFault(targetFamily: targetFamily, viewName: "FamilyDashboardView")
        // WHY aggregated view intentionally does NOT push profile filter: FamilyDashboard is
        // family-aggregated for the parent role — it renders cross-hero totals, child account
        // cards, and the pending approval queue across all profiles. Adding a profile
        // predicate here would incorrectly narrow the cache slice and break aggregation;
        // family-only scoping with stable sorts is the correct isolation boundary for this screen.
        let profileFilter = ProfileCache.familyPredicate(familyRecordName: targetFamily)
        let questFilter = QuestCache.familyPredicate(familyRecordName: targetFamily)
        let completionFilter = QuestCompletionCache.familyPredicate(familyRecordName: targetFamily)
        let ledgerFilter = LedgerEntryCache.familyPredicate(familyRecordName: targetFamily)
        let allowanceFilter = AllowancePeriodCache.familyPredicate(familyRecordName: targetFamily)
        let achievementFilter = AchievementCache.familyPredicate(familyRecordName: targetFamily)
        let profileAchievementFilter = ProfileAchievementCache.familyPredicate(familyRecordName: targetFamily)
        let templateFilter = QuestTemplateCache.familyPredicate(familyRecordName: targetFamily)
        let familyFilter = FamilyCache.recordPredicate(recordName: targetFamily)
        // WHY stable sorts: secondary recordName keeps ordering deterministic across CloudKit merge reorders.
        _cachedProfiles = Query(
            filter: profileFilter,
            sort: [SortDescriptor(\ProfileCache.displayName), SortDescriptor(\ProfileCache.recordName)]
        )
        _cachedQuests = Query(
            filter: questFilter,
            sort: [SortDescriptor(\QuestCache.weekOf, order: .reverse), SortDescriptor(\QuestCache.recordName)]
        )
        _cachedCompletions = Query(
            filter: completionFilter,
            sort: [SortDescriptor(\QuestCompletionCache.completedDate, order: .reverse), SortDescriptor(\QuestCompletionCache.recordName)]
        )
        _cachedLedgers = Query(
            filter: ledgerFilter,
            sort: [SortDescriptor(\LedgerEntryCache.date, order: .reverse), SortDescriptor(\LedgerEntryCache.recordName)]
        )
        _cachedAllowancePeriods = Query(
            filter: allowanceFilter,
            sort: [SortDescriptor(\AllowancePeriodCache.weekOf, order: .reverse), SortDescriptor(\AllowancePeriodCache.recordName)]
        )
        _cachedAchievements = Query(
            filter: achievementFilter,
            sort: [SortDescriptor(\AchievementCache.name), SortDescriptor(\AchievementCache.recordName)]
        )
        _cachedProfileAchievements = Query(
            filter: profileAchievementFilter,
            sort: [SortDescriptor(\ProfileAchievementCache.earnedDate, order: .reverse), SortDescriptor(\ProfileAchievementCache.recordName)]
        )
        _cachedTemplates = Query(
            filter: templateFilter,
            sort: [SortDescriptor(\QuestTemplateCache.name), SortDescriptor(\QuestTemplateCache.recordName)]
        )
        // WHY single-row root lookup rides the recordName index; secondary sort never reorders.
        _cachedFamilies = Query(
            filter: familyFilter,
            sort: [SortDescriptor(\FamilyCache.name), SortDescriptor(\FamilyCache.recordName)]
        )
        // WHY: single-row scope keeps role and displayName cache-derived instead of session-derived.
        if let targetProfile = profileRecordName.sanitizedNilIfEmpty {
            _currentProfileRows = Query(
                filter: ProfileCache.recordPredicate(recordName: targetProfile, familyRecordName: targetFamily),
                sort: [SortDescriptor(\ProfileCache.displayName), SortDescriptor(\ProfileCache.recordName)]
            )
        } else {
            // WHY: family fallback keeps viewer gating live before the profile param propagates; row still resolves via session identity.
            _currentProfileRows = Query(
                filter: ProfileCache.familyPredicate(familyRecordName: targetFamily),
                sort: [SortDescriptor(\ProfileCache.displayName), SortDescriptor(\ProfileCache.recordName)]
            )
        }
    }

    /// Queried cache row for the active viewer; nil when scope has no synced row (fail-closed rendering).
    private var currentProfileRow: ProfileCache? {
        // WHY: resolver keeps empty-scope fail-closed while session identity bridges bootstrap before the param propagates.
        ProfileRowResolver.resolve(rows: currentProfileRows, targetRecordName: profileRecordName ?? appState.currentProfile?.id.recordName)
    }

    /// Queried family row; nil when scope has no synced row (fail-closed rendering).
    private var cachedFamilyRow: FamilyCache? {
        cachedFamilies.first
    }

    /// Viewer role derived from cache so gating never reads session domain state.
    private var viewerRole: UserRole? {
        currentProfileRow?.roleEnum
    }

    private var viewerIsHero: Bool {
        viewerRole == .hero
    }

    private var viewerIsGuildMaster: Bool {
        viewerRole == .guildMaster
    }

    // MARK: - Transaction Sheet State

    @State private var showDepositSheet = false
    @State private var showWithdrawSheet = false
    @State private var selectedChildForTransaction: ProfileCache?
    @State private var transactionVM: HeroLedgerViewModel?
    @State private var maxChildCardHeight: CGFloat?
    @State private var isProcessingPayout = false
    @State private var rebuildTask: Task<Void, Never>?

    private var targetFamilyForStale: String {
        familyRecordName ?? appState.family?.id.recordName ?? ""
    }

    @ViewBuilder
    private var questStaleBanner: some View {
        if !targetFamilyForStale.isEmpty {
            StaleDataBanner(
                family: targetFamilyForStale,
                type: .quest,
                count: cachedQuests.count,
                isSyncing: lifecycleCoordinator?.isSyncing == true
            )
        }
    }

    private var selectedChildProfile: ProfileCache? {
        guard let name = selectedChildRecordName else { return nil }
        return cachedProfiles.first { $0.recordName == name }
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularSplitView
            } else {
                compactNavigationStack
            }
        }
        // WHY: view identity tracks family+profile so @Query predicates (init-captured) are recreated on scope switch.
        .id("\(familyRecordName ?? "")-\(profileRecordName ?? "")")
        .sheet(item: $sharePresentation) { presentation in
            CloudSharingControllerWrapper(presentation: presentation)
        }
        .sheet(isPresented: $showRolePicker) {
            InviteRolePickerView { role in
                await presentInviteShare(for: role)
            }
        }
        .onChange(of: viewModel?.loadError) { _, newError in
            if let error = newError {
                toastManager.show(message: error, type: .error)
            }
        }
        // Deposit sheet: child picker → transaction form.
        .sheet(isPresented: $showDepositSheet) {
            if let child = selectedChildForTransaction,
               let vm = transactionVM
            {
                HeroTransactionView(mode: .deposit, viewModel: vm, heroName: child.displayName)
            }
        }
        .onChange(of: selectedChildForTransaction) { _, child in
            guard let child else { return }
            transactionVM = HeroLedgerViewModel(
                heroProfile: child,
                spending: spending,
                appState: appState
            )
        }
        .sheet(isPresented: $showWithdrawSheet) {
            if let child = selectedChildForTransaction,
               let vm = transactionVM
            {
                HeroTransactionView(mode: .withdraw, viewModel: vm, heroName: child.displayName)
            }
        }
    }

    // MARK: - Regular Split View

    private var regularSplitView: some View {
        ViewThatFitsSplit {
            regularSplitContent
        } compactContent: {
            compactNavigationStack
        }
    }

    private var regularSplitContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            regularSidebarColumn
        } detail: {
            regularDetailColumn
        }
        .inspector(isPresented: $showPendingInspector) {
            pendingInspectorContent
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarRole(.editor)
        .maxContentWidth()
    }

    private var regularSidebarColumn: some View {
        regularSidebarScrollContent()
            .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
            .navigationTitle(cachedFamilyRow?.name ?? "Guild")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { pendingToggleToolbar }
            .modifier(
                DashboardSidebarLifecycle(
                    cachedProfiles: cachedProfiles,
                    cachedQuests: cachedQuests,
                    cachedCompletions: cachedCompletions,
                    cachedLedgers: cachedLedgers,
                    cachedAllowancePeriods: cachedAllowancePeriods,
                    cachedAchievements: cachedAchievements,
                    cachedProfileAchievements: cachedProfileAchievements,
                    childCardID: viewModel?.childAccountCards.first?.id,
                    onAppear: { await handleRegularAppear() },
                    onRefresh: {
                        await lifecycleCoordinator?.performManualSync()
                        await viewModel?.refresh()
                    },
                    onProfilesChanged: { scheduleRebuild(includingInvitations: true) },
                    onCacheChanged: { scheduleRebuild() },
                    onAutoSelect: { autoSelectFirstHero() },
                    onDisappear: { handleSidebarDisappear() }
                )
            )
    }

    private func regularSidebarScrollContent() -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                regularSidebarStack(scrollProxy: scrollProxy)
            }
        }
    }

    private func regularSidebarStack(scrollProxy: ScrollViewProxy) -> some View {
        VStack(spacing: 18) {
            questStaleBanner
            regularSidebarBranch(scrollProxy: scrollProxy)
        }
        .maxContentWidth()
        .padding(.horizontal)
        .padding(.vertical, DesignSystemConstants.Padding.medium)
    }

    @ViewBuilder
    private func regularSidebarBranch(scrollProxy: ScrollViewProxy) -> some View {
        if let vm = viewModel {
            FamilyDashboardContentView {
                regularDashboardContent(vm: vm, scrollProxy: scrollProxy)
            }
        } else {
            FamilyDashboardEmptyView()
        }
    }

    @ViewBuilder
    private var regularDetailColumn: some View {
        if let hero = selectedChildProfile {
            HeroDetailInlineView(
                hero: hero,
                familyRecordName: familyRecordName ?? appState.family?.id.recordName,
                ledgers: cachedLedgers,
                spending: spending,
                onDeposit: {
                    selectedChildForTransaction = hero
                    showDepositSheet = true
                },
                onWithdraw: {
                    selectedChildForTransaction = hero
                    showWithdrawSheet = true
                }
            )
        } else {
            ContentUnavailableView(
                "Select a Hero",
                systemImage: "person.2",
                description: Text("Choose a child card to inspect balance, buckets, and recent ledger activity.")
            )
        }
    }

    private var pendingInspectorContent: some View {
        ScrollView {
            pendingApprovalQueueSection()
                .padding(.vertical, 12)
        }
        // WHY: inspector width is a design token so 50/50 split and outer 1040 cap stay in sync.
        .frame(width: DesignSystemConstants.Layout.inspectorWidth)
        .background(Color(DesignSystemConstants.Colors.background))
    }

    @ToolbarContentBuilder
    private var pendingToggleToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            pendingToggleButton
        }
    }

    private var pendingToggleButton: some View {
        let title = showPendingInspector ? "Hide pending queue" : "Show pending queue"
        let icon = showPendingInspector ? "sidebar.right.slash" : "sidebar.right"
        return Button {
            withAnimation { showPendingInspector.toggle() }
            HapticsService.lightImpact()
        } label: {
            Label(title, systemImage: icon)
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier("dashboard.togglePendingInspectorButton")
    }

    private func handleRegularAppear() async {
        ensureViewModel()
        ensureSyncHost()
        if let vm = viewModel, let host = syncHost {
            host.subscribe(viewModel: vm, coordinator: appSyncCoordinator)
        }
        await lifecycleCoordinator?.performManualSync()
        await viewModel?.refresh()
        await viewModel?.refreshInvitations()
        autoSelectFirstHero()
    }

    private func handleCompactAppear() async {
        ensureViewModel()
        ensureSyncHost()
        if let vm = viewModel, let host = syncHost {
            host.subscribe(viewModel: vm, coordinator: appSyncCoordinator)
        }
        await lifecycleCoordinator?.performManualSync()
        await viewModel?.refresh()
        await viewModel?.refreshInvitations()
    }

    private func autoSelectFirstHero() {
        if selectedChildRecordName == nil {
            selectedChildRecordName = viewModel?.childAccountCards.first?.profile.recordName
        }
    }

    private func handleSidebarDisappear() {
        rebuildTask?.cancel()
        rebuildTask = nil
        if let host = syncHost {
            host.unsubscribe(coordinator: appSyncCoordinator)
        }
    }

    @MainActor
    private func ensureSyncHost() {
        if syncHost == nil {
            syncHost = DashboardSyncHost()
        }
    }

    private var compactNavigationStack: some View {
        NavigationStack {
            compactScrollContent
        }
    }

    private var compactScrollContent: some View {
        compactScrollBase
            .modifier(
                DashboardSidebarLifecycle(
                    cachedProfiles: cachedProfiles,
                    cachedQuests: cachedQuests,
                    cachedCompletions: cachedCompletions,
                    cachedLedgers: cachedLedgers,
                    cachedAllowancePeriods: cachedAllowancePeriods,
                    cachedAchievements: cachedAchievements,
                    cachedProfileAchievements: cachedProfileAchievements,
                    childCardID: nil,
                    onAppear: { await handleCompactAppear() },
                    onRefresh: {
                        await lifecycleCoordinator?.performManualSync()
                        await viewModel?.refresh()
                    },
                    onProfilesChanged: { scheduleRebuild(includingInvitations: true) },
                    onCacheChanged: { scheduleRebuild() },
                    onAutoSelect: {},
                    onDisappear: { handleSidebarDisappear() }
                )
            )
    }

    private var compactScrollBase: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                compactStack(scrollProxy: scrollProxy)
            }
        }
        .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
        .navigationTitle(cachedFamilyRow?.name ?? "Guild")
        .navigationBarTitleDisplayMode(.large)
    }

    private func compactStack(scrollProxy: ScrollViewProxy) -> some View {
        VStack(spacing: 18) {
            questStaleBanner
                .padding(.horizontal)
            compactBranch(scrollProxy: scrollProxy)
        }
        .maxContentWidth()
        .padding(.horizontal)
        .padding(.vertical, DesignSystemConstants.Padding.medium)
    }

    @ViewBuilder
    private func compactBranch(scrollProxy: ScrollViewProxy) -> some View {
        if let vm = viewModel {
            FamilyDashboardContentView {
                compactDashboardContent(vm: vm, scrollProxy: scrollProxy)
            }
        } else {
            FamilyDashboardEmptyView()
        }
    }

    @ViewBuilder
    private func regularDashboardContent(vm: FamilyDashboardViewModel, scrollProxy: ScrollViewProxy) -> some View {
        FamilyDashboardStatCardsSection(
            outflow: vm.familyOutflow,
            pendingCount: pendingCount,
            onJumpToPending: {
                withAnimation {
                    scrollProxy.scrollTo("pendingQueueAnchor", anchor: .top)
                }
                HapticsService.rigid()
            }
        )
        earningSparklineHeader
        FamilyDashboardChildAccountsSection(
            cards: vm.childAccountCards,
            isGuildMaster: viewerIsGuildMaster,
            showRolePicker: $showRolePicker,
            onHeightChange: { maxChildCardHeight = $0 },
            cardContent: { card in childAccountCardContainer(card: card, vm: vm) }
        )
        HStack(alignment: .top, spacing: 16) {
            weeklySummarySection(summary: vm.weekSummary)
                .frame(maxWidth: .infinity)
            if showPendingInspector {
                pendingApprovalQueueSection()
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func compactDashboardContent(vm: FamilyDashboardViewModel, scrollProxy: ScrollViewProxy) -> some View {
        FamilyDashboardStatCardsSection(
            outflow: vm.familyOutflow,
            pendingCount: pendingCount,
            onJumpToPending: {
                withAnimation {
                    scrollProxy.scrollTo("pendingQueueAnchor", anchor: .top)
                }
                HapticsService.rigid()
            }
        )
        FamilyDashboardChildAccountsSection(
            cards: vm.childAccountCards,
            isGuildMaster: viewerIsGuildMaster,
            showRolePicker: $showRolePicker,
            onHeightChange: { maxChildCardHeight = $0 },
            cardContent: { card in childAccountCardContainer(card: card, vm: vm) }
        )
        pendingApprovalQueueSection()
        weeklySummarySection(summary: vm.weekSummary)
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
        }, rebuild: { vm in rebuild(vm) })
    }

    @MainActor
    private func rebuild(_ vm: FamilyDashboardViewModel? = nil) {
        maxChildCardHeight = nil
        (vm ?? viewModel)?.rebuildLists(
            profiles: cachedProfiles,
            quests: cachedQuests,
            logs: cachedCompletions,
            ledgers: cachedLedgers,
            allowancePeriods: cachedAllowancePeriods,
            profileAchievements: cachedProfileAchievements,
            achievements: cachedAchievements,
            templates: cachedTemplates
        )
    }

    @MainActor
    private func scheduleRebuild(includingInvitations: Bool = false) {
        // WHY no Task capture: @Model rows cannot cross isolation, so rebuild runs synchronously on MainActor.
        maxChildCardHeight = nil
        rebuildTask?.cancel()
        rebuild()
        guard includingInvitations else {
            rebuildTask = nil
            return
        }
        let targetVM = viewModel
        rebuildTask = Task { [targetVM] in
            guard !Task.isCancelled else { return }
            await targetVM?.refreshInvitations()
        }
    }
}

// MARK: - Sections (container owns Queries, sections render value slices)

private extension FamilyDashboardView {
    // MARK: - Earning Sparkline

    @ViewBuilder
    private var earningSparklineHeader: some View {
        if horizontalSizeClass == .regular {
            let points = sparklinePoints
            let total = FamilyDashboardViewModel.sparklineTotal(for: points)
            FamilyDashboardSparklineCard(points: points, total: total)
        }
    }

    private var sparklinePoints: [WeeklyEarningPoint] {
        FamilyDashboardViewModel.sparklinePoints(
            periods: cachedAllowancePeriods,
            // WHY: row-first payout day keeps week math cache-derived with fail-closed default.
            payoutDay: currentProfileRow?.payoutDayEnum ?? cachedFamilyRow?.payoutDayEnum ?? .sunday,
            selectedProfile: selectedChildRecordName
        )
    }

    // MARK: - Child Account Cards (container-owned Query slices fan out here)

    @ViewBuilder
    private func childAccountCardContainer(card: ChildAccountCard, vm _: FamilyDashboardViewModel) -> some View {
        let isRegular = horizontalSizeClass == .regular
        if isRegular {
            regularChildCardButton(card: card)
        } else {
            compactChildCardLink(card: card)
        }
    }

    private func regularChildCardButton(card: ChildAccountCard) -> some View {
        let isSelected = selectedChildRecordName == card.profile.recordName
        let borderColor = isSelected ? Color(DesignSystemConstants.Colors.accentBlue) : Color.secondary.opacity(0.12)
        let borderWidth: CGFloat = isSelected ? 2 : 1
        return Button {
            withAnimation { selectedChildRecordName = card.profile.recordName }
            HapticsService.lightImpact()
        } label: {
            DashboardChildCardContent(card: card, minHeight: maxChildCardHeight, isRegular: true)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: borderWidth)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View \(card.profile.displayName)'s account")
        .accessibilityIdentifier("dashboard.childAccount-\(card.profile.recordName)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func compactChildCardLink(card: ChildAccountCard) -> some View {
        NavigationLink {
            HeroDetailView(
                hero: card.profile,
                familyRecordName: familyRecordName ?? appState.family?.id.recordName,
                spending: spending
            )
            .environment(questService)
            .environment(familyService)
            .environment(appState)
            .environment(appSyncCoordinator)
        } label: {
            DashboardChildCardContent(card: card, minHeight: maxChildCardHeight, isRegular: false)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View \(card.profile.displayName)'s account")
        .accessibilityIdentifier("dashboard.childAccount-\(card.profile.recordName)")
    }

    // MARK: - Pending Approval Queue (focused section)

    func pendingApprovalQueueSection() -> some View {
        FamilyDashboardPendingQueueView(
            pending: pendingCompletions,
            profiles: cachedProfiles,
            quests: cachedQuests,
            viewerIsHero: viewerIsHero,
            onApprove: { completion in
                let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: completion)
                // WHY snapshot: @Model rows cannot cross isolation; Sendable struct rides the Task.
                let domainLog = completion.toQuestCompletion(zoneID: zoneID)
                Task { [domainLog] in
                    await approveCompletion(domainLog)
                }
            },
            onReject: { completion in
                let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: completion)
                // WHY snapshot: @Model rows cannot cross isolation; Sendable struct rides the Task.
                let domainLog = completion.toQuestCompletion(zoneID: zoneID)
                Task { [domainLog] in
                    await rejectCompletion(domainLog)
                }
            }
        )
    }

    var pendingCompletions: [QuestCompletionCache] {
        FamilyDashboardViewModel.pendingCompletions(from: cachedCompletions)
    }

    var pendingCount: Int {
        pendingCompletions.count
    }

    @MainActor
    func approveCompletion(_ domainLog: QuestCompletion) async {
        // WHY: mutation actor derives from the cache row so verify never reads session domain state.
        guard let row = currentProfileRow else { return }
        let parent = row.toProfile(zoneID: appState.resolvedFamilyZoneID())
        do {
            _ = try await questService.verify(questLog: domainLog, by: parent)
            HapticsService.success()
            rebuild()
        } catch {
            toastManager.show(
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                type: .error
            )
        }
    }

    @MainActor
    func rejectCompletion(_ domainLog: QuestCompletion) async {
        // WHY: mutation actor derives from the cache row so verify never reads session domain state.
        guard let row = currentProfileRow else { return }
        let parent = row.toProfile(zoneID: appState.resolvedFamilyZoneID())
        do {
            _ = try await questService.reject(questLog: domainLog, by: parent)
            HapticsService.warning()
            rebuild()
        } catch {
            toastManager.show(
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                type: .error
            )
        }
    }

    // MARK: - Weekly Summary & Payout (focused section)

    func weeklySummarySection(summary: WeekendSummary?) -> some View {
        FamilyDashboardWeeklySummaryView(
            summary: summary,
            lootDayTitle: cachedFamilyRow?.payoutDayEnum?.lootDayTitle ?? "Sunday Allowance Day",
            viewerIsHero: viewerIsHero,
            familyPayoutPolicy: cachedFamilyRow?.payoutPolicyEnum,
            isProcessingPayout: isProcessingPayout,
            onConfirmPayout: processPayout
        )
    }

    @MainActor
    func processPayout() async {
        isProcessingPayout = true
        defer { isProcessingPayout = false }
        guard appState.family != nil else { return }
        let zoneID = appState.resolvedFamilyZoneID()
        let matchingPeriods = cachedAllowancePeriods.filter { period in
            let status = period.statusEnum
            return status == .active || status == .payoutPending
        }
        let activePeriods = matchingPeriods.map { $0.toAllowancePeriod(zoneID: zoneID) }
        for period in activePeriods {
            do {
                _ = try await treasury.runPayout(period: period)
            } catch {
                toastManager.show(
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    type: .error
                )
            }
        }
    }

    @MainActor
    func presentInviteShare(for role: UserRole) async {
        guard let presentation = await viewModel?.prepareInviteShare(for: role) else {
            Self.logger.warning("Invite share preparation failed for role \(role.rawValue, privacy: .public)")
            toastManager.show(message: "Could not create an invitation. Please try again.", type: .error)
            return
        }
        guard presentation.shareURL != nil else {
            Self.logger.warning("Invite share missing URL for role \(role.rawValue, privacy: .public)")
            toastManager.show(message: "Could not generate a share link for this invitation. Please try again.", type: .error)
            return
        }
        sharePresentation = presentation
    }
}

/// WHY container/sections: FamilyDashboardView owns the 10 Queries, sections render value slices without touching the store.
struct FamilyDashboardStatCardsSection: View {
    let outflow: Int64
    let pendingCount: Int
    let onJumpToPending: () -> Void

    var body: some View {
        HStack(spacing: DesignSystemConstants.Padding.medium) {
            StatCard(
                title: "FAMILY OUTFLOW",
                value: CurrencyFormatter.string(outflow),
                icon: "banknote.fill",
                tint: Color(DesignSystemConstants.Colors.primaryGreen),
                accessibilityID: "dashboard.outflowCard"
            )

            Button(action: onJumpToPending) {
                StatCard(
                    title: "PENDING REVIEW",
                    value: "\(pendingCount)",
                    icon: "hourglass",
                    tint: Color(DesignSystemConstants.Colors.pendingAmber),
                    accessibilityID: "dashboard.pendingReviewCard"
                )
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
        }
    }
}

/// WHY value slices: cards and flags arrive as values so grid ordering never re-queries the store.
struct FamilyDashboardChildAccountsSection<CardContent: View>: View {
    let cards: [ChildAccountCard]
    let isGuildMaster: Bool
    @Binding var showRolePicker: Bool
    let onHeightChange: (CGFloat) -> Void
    @ViewBuilder let cardContent: (ChildAccountCard) -> CardContent

    var body: some View {
        VStack(spacing: 12) {
            SectionHeader("CHILD ACCOUNTS") {
                if isGuildMaster {
                    DashboardInviteButton(showRolePicker: $showRolePicker)
                }
            }

            if cards.isEmpty {
                DashboardEmptyChildrenCard(isGuildMaster: isGuildMaster)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 14)
                    ],
                    spacing: 14
                ) {
                    ForEach(cards) { card in
                        cardContent(card)
                    }
                }
                .onPreferenceChange(ChildCardHeightPreferenceKey.self) { newHeight in
                    if newHeight > 0 {
                        onHeightChange(newHeight)
                    }
                }
            }
        }
    }
}
