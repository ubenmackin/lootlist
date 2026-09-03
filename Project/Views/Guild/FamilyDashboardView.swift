//
//  FamilyDashboardView.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import Charts
import os
import SwiftData
import SwiftUI

struct FamilyDashboardView: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "FamilyDashboardView")
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
    @State private var showRolePicker: Bool = false
    @State private var sharePresentation: CloudSharePresentation?
    @State private var selectedChildRecordName: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State private var showPendingInspector = false

    @Query private var cachedProfiles: [ProfileCache]
    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]
    @Query private var cachedAchievements: [AchievementCache]
    @Query private var cachedProfileAchievements: [ProfileAchievementCache]

    /// Family record name used to push the family filter down to SwiftData.
    /// When `nil` (no family loaded) the queries return zero rows, which is
    /// the correct behavior — there is no family to scope to.
    private let spending: SpendingService
    private let familyRecordName: String?

    init(spending: SpendingService, familyRecordName: String? = nil) {
        self.spending = spending
        self.familyRecordName = familyRecordName

        let targetFamily = familyRecordName ?? ""
        FamilyScopeValidator.validateOrFault(targetFamily: targetFamily, viewName: "FamilyDashboardView")
        // WHY aggregated view intentionally does NOT push profile filter: FamilyDashboard is
        // family-aggregated for the parent role — it renders cross-hero totals, child account
        // cards, and the pending approval queue across all profiles. Adding a profile
        // predicate here would incorrectly narrow the cache slice and break aggregation;
        // family-only scoping with stable sorts is the correct isolation boundary for this screen.
        let profileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily }
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
        let allowanceFilter = #Predicate<AllowancePeriodCache> { $0.familyRecordName == targetFamily }
        let achievementFilter = #Predicate<AchievementCache> { $0.familyRecordName == targetFamily }
        let profileAchievementFilter = #Predicate<ProfileAchievementCache> { $0.familyRecordName == targetFamily }
        _cachedProfiles = Query(
            filter: profileFilter,
            sort: \ProfileCache.displayName
        )
        _cachedQuests = Query(
            filter: questFilter,
            sort: \QuestCache.weekOf,
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
        _cachedAllowancePeriods = Query(
            filter: allowanceFilter,
            sort: \AllowancePeriodCache.weekOf,
            order: .reverse
        )
        _cachedAchievements = Query(
            filter: achievementFilter,
            sort: \AchievementCache.name
        )
        _cachedProfileAchievements = Query(
            filter: profileAchievementFilter,
            sort: \ProfileAchievementCache.earnedDate,
            order: .reverse
        )
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
        .sheet(isPresented: $showRolePicker) {
            InviteRolePickerView { role in
                await presentInviteShare(for: role)
            }
        }
        .sheet(item: $sharePresentation) { presentation in
            CloudSharingControllerWrapper(presentation: presentation)
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
            NavigationSplitView(columnVisibility: $columnVisibility) {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(spacing: 18) {
                            questStaleBanner
                            if let vm = viewModel {
                                regularDashboardContent(vm: vm, scrollProxy: scrollProxy)
                            } else {
                                DashboardLoadingPlaceholder()
                            }
                        }
                        .maxContentWidth()
                        .padding(.horizontal)
                        .padding(.vertical, DesignSystemConstants.Padding.medium)
                    }
                }
                .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
                .navigationTitle(appState.family?.name ?? "Guild")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            withAnimation { showPendingInspector.toggle() }
                            HapticsService.lightImpact()
                        } label: {
                            Label(showPendingInspector ? "Hide pending queue" : "Show pending queue", systemImage: showPendingInspector ? "sidebar.right.slash" : "sidebar.right")
                        }
                        .accessibilityLabel(showPendingInspector ? "Hide pending queue" : "Show pending queue")
                        .accessibilityIdentifier("dashboard.togglePendingInspectorButton")
                    }
                }
                .refreshable {
                    await lifecycleCoordinator?.performManualSync()
                    await viewModel?.refresh()
                }
                .task {
                    ensureViewModel()
                    viewModel?.subscribeToSyncEvents(appSyncCoordinator)
                    await lifecycleCoordinator?.performManualSync()
                    await viewModel?.refresh()
                    await viewModel?.refreshInvitations()
                    if selectedChildRecordName == nil {
                        selectedChildRecordName = viewModel?.childAccountCards.first?.profile.recordName
                    }
                }
                .onChange(of: viewModel?.childAccountCards.first?.id) { _, _ in
                    if selectedChildRecordName == nil {
                        selectedChildRecordName = viewModel?.childAccountCards.first?.profile.recordName
                    }
                }
                .onChange(of: cachedProfiles) { _, _ in
                    scheduleRebuild(includingInvitations: true)
                }
                .onChange(of: cachedQuests) { _, _ in scheduleRebuild() }
                .onChange(of: cachedCompletions) { _, _ in scheduleRebuild() }
                .onChange(of: cachedLedgers) { _, _ in scheduleRebuild() }
                .onChange(of: cachedAllowancePeriods) { _, _ in scheduleRebuild() }
                .onChange(of: cachedAchievements) { _, _ in scheduleRebuild() }
                .onChange(of: cachedProfileAchievements) { _, _ in scheduleRebuild() }
                .onDisappear {
                    rebuildTask?.cancel()
                    rebuildTask = nil
                    viewModel?.unsubscribeFromSyncEvents(appSyncCoordinator)
                }
            } detail: {
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
            .inspector(isPresented: $showPendingInspector) {
                ScrollView {
                    pendingApprovalQueueSection()
                        .padding(.vertical, 12)
                }
                // WHY: inspector width is a design token so 50/50 split and outer 1040 cap stay in sync.
                .frame(width: DesignSystemConstants.Layout.inspectorWidth)
                .background(Color(DesignSystemConstants.Colors.background))
            }
            .navigationSplitViewStyle(.balanced)
            .toolbarRole(.editor)
            .maxContentWidth()
        } compactContent: {
            compactNavigationStack
        }
    }

    private var compactNavigationStack: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 18) {
                        questStaleBanner
                            .padding(.horizontal)
                        if let vm = viewModel {
                            compactDashboardContent(vm: vm, scrollProxy: scrollProxy)
                        } else {
                            DashboardLoadingPlaceholder()
                        }
                    }
                    .maxContentWidth()
                    .padding(.horizontal)
                    .padding(.vertical, DesignSystemConstants.Padding.medium)
                }
            }
            .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
            .navigationTitle(appState.family?.name ?? "Guild")
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                await lifecycleCoordinator?.performManualSync()
                await viewModel?.refresh()
            }
            .task {
                ensureViewModel()
                viewModel?.subscribeToSyncEvents(appSyncCoordinator)
                await lifecycleCoordinator?.performManualSync()
                await viewModel?.refresh()
                await viewModel?.refreshInvitations()
            }
            .onChange(of: cachedProfiles) { _, _ in
                scheduleRebuild(includingInvitations: true)
            }
            .onChange(of: cachedQuests) { _, _ in scheduleRebuild() }
            .onChange(of: cachedCompletions) { _, _ in scheduleRebuild() }
            .onChange(of: cachedLedgers) { _, _ in scheduleRebuild() }
            .onChange(of: cachedAllowancePeriods) { _, _ in scheduleRebuild() }
            .onChange(of: cachedAchievements) { _, _ in scheduleRebuild() }
            .onChange(of: cachedProfileAchievements) { _, _ in scheduleRebuild() }
            .onDisappear {
                rebuildTask?.cancel()
                rebuildTask = nil
                viewModel?.unsubscribeFromSyncEvents(appSyncCoordinator)
            }
        }
    }

    @ViewBuilder
    private func regularDashboardContent(vm: FamilyDashboardViewModel, scrollProxy: ScrollViewProxy) -> some View {
        statCardsRow(vm: vm, scrollProxy: scrollProxy)
        earningSparklineHeader
        childAccountsSection(vm: vm)
        depositWithdrawSection(vm: vm)
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
        statCardsRow(vm: vm, scrollProxy: scrollProxy)
        childAccountsSection(vm: vm)
        depositWithdrawSection(vm: vm)
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
            achievements: cachedAchievements
        )
    }

    @MainActor
    private func scheduleRebuild(includingInvitations: Bool = false) {
        // Coalesce multi-query updates into a single task to prevent torn UI state.
        let profiles = cachedProfiles
        let quests = cachedQuests
        let logs = cachedCompletions
        let ledgers = cachedLedgers
        let periods = cachedAllowancePeriods
        let profileAchievements = cachedProfileAchievements
        let achievements = cachedAchievements
        let targetVM = viewModel
        maxChildCardHeight = nil
        rebuildTask?.cancel()
        rebuildTask = Task { [targetVM, profiles, quests, logs, ledgers, periods, profileAchievements, achievements] in
            guard !Task.isCancelled else { return }
            targetVM?.rebuildLists(
                profiles: profiles,
                quests: quests,
                logs: logs,
                ledgers: ledgers,
                allowancePeriods: periods,
                profileAchievements: profileAchievements,
                achievements: achievements
            )
            if includingInvitations {
                guard !Task.isCancelled else { return }
                await targetVM?.refreshInvitations()
            }
        }
    }
}

// MARK: - Sections (consolidated here for file-scope isolation)

private extension FamilyDashboardView {
    // MARK: - Stat Cards

    func statCardsRow(vm: FamilyDashboardViewModel, scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: DesignSystemConstants.Padding.medium) {
            StatCard(
                title: "FAMILY OUTFLOW",
                value: CurrencyFormatter.string(vm.familyOutflow),
                icon: "banknote.fill",
                tint: Color(DesignSystemConstants.Colors.primaryGreen),
                accessibilityID: "dashboard.outflowCard"
            )

            Button {
                withAnimation {
                    scrollProxy.scrollTo("pendingQueueAnchor", anchor: .top)
                }
                HapticsService.rigid()
            } label: {
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

    // MARK: - Earning Sparkline

    @ViewBuilder
    private var earningSparklineHeader: some View {
        if horizontalSizeClass == .regular {
            let points = sparklinePoints
            let total = points.reduce(0) { $0 + $1.amount }
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("EARNING TREND — 6 WEEKS") {
                    Text(CurrencyFormatter.string(total))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                }
                if points.allSatisfy({ $0.amount == 0 }) {
                    Text("No earnings yet — complete quests to see the trend.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(height: 80, alignment: .center)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                                .fill(Color(DesignSystemConstants.Colors.cardSurface))
                        )
                } else {
                    Chart(points) { point in
                        BarMark(
                            x: .value("Week", point.label),
                            y: .value("Earned", point.amount)
                        )
                        .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                        .cornerRadius(4)
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .automatic) { _ in
                            AxisValueLabel()
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    .frame(height: 80)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                            .fill(Color(DesignSystemConstants.Colors.cardSurface))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
                    )
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("6 week earning trend")
            .accessibilityIdentifier("dashboard.earningSparkline")
        }
    }

    private var sparklinePoints: [WeeklyEarningPoint] {
        let payoutDay = appState.family?.payoutDay ?? .sunday
        let currentStart = WeekMath.startOfWeek(for: Date(), payoutDay: payoutDay)
        var result: [WeeklyEarningPoint] = []
        let sourcePeriods = cachedAllowancePeriods
        for offset in 0 ..< 6 {
            let weekStart = WeekMath.weekStart(byAddingWeeks: -(5 - offset), to: currentStart)
            let weekRange = WeekMath.weekRange(starting: weekStart)
            let total: Double = sourcePeriods.filter {
                weekRange.contains($0.weekOf)
            }.reduce(0) { $0 + $1.totalEarned }
            let label = weekStart.formatted(.dateTime.month(.abbreviated).day())
            let heroFiltered: Double
            if let selected = selectedChildRecordName {
                heroFiltered = sourcePeriods.filter {
                    $0.profileRecordName == selected && weekRange.contains($0.weekOf)
                }.reduce(0) { $0 + $1.totalEarned }
                result.append(WeeklyEarningPoint(id: WeekMath.dayKey(for: weekStart), weekStart: weekStart, label: label, amount: heroFiltered))
            } else {
                result.append(WeeklyEarningPoint(id: WeekMath.dayKey(for: weekStart), weekStart: weekStart, label: label, amount: total))
            }
        }
        return result
    }

    // MARK: - Child Accounts Grid

    private func childAccountsSection(vm: FamilyDashboardViewModel) -> some View {
        VStack(spacing: 12) {
            SectionHeader("CHILD ACCOUNTS") {
                if appState.currentProfile?.role == .guildMaster {
                    DashboardInviteButton(showRolePicker: $showRolePicker)
                }
            }

            if vm.childAccountCards.isEmpty {
                DashboardEmptyChildrenCard(isGuildMaster: appState.currentProfile?.role == .guildMaster)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 14)
                    ],
                    spacing: 14
                ) {
                    ForEach(vm.childAccountCards) { card in
                        childAccountCardContainer(card: card, vm: vm)
                    }
                }
                .onPreferenceChange(ChildCardHeightPreferenceKey.self) { newHeight in
                    if newHeight > 0, maxChildCardHeight != newHeight {
                        maxChildCardHeight = newHeight
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func childAccountCardContainer(card: ChildAccountCard, vm _: FamilyDashboardViewModel) -> some View {
        if horizontalSizeClass == .regular {
            let isSelected = selectedChildRecordName == card.profile.recordName
            Button {
                withAnimation { selectedChildRecordName = card.profile.recordName }
                HapticsService.lightImpact()
            } label: {
                DashboardChildCardContent(card: card, minHeight: maxChildCardHeight, isRegular: horizontalSizeClass == .regular)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color(DesignSystemConstants.Colors.accentBlue) : Color.secondary.opacity(0.12),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(card.profile.displayName)'s account")
            .accessibilityIdentifier("dashboard.childAccount-\(card.profile.recordName)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
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
                DashboardChildCardContent(card: card, minHeight: maxChildCardHeight, isRegular: horizontalSizeClass == .regular)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(card.profile.displayName)'s account")
            .accessibilityIdentifier("dashboard.childAccount-\(card.profile.recordName)")
        }
    }

    // MARK: - Deposit / Withdraw Shortcut

    @ViewBuilder
    func depositWithdrawSection(vm: FamilyDashboardViewModel) -> some View {
        if !vm.childAccountCards.isEmpty {
            VStack(spacing: 12) {
                SectionHeader("QUICK ACTIONS")

                HStack(spacing: 12) {
                    DashboardQuickActionButton(
                        title: "Deposit",
                        icon: "plus.circle.fill",
                        color: Color(DesignSystemConstants.Colors.primaryGreen),
                        identifier: "dashboard.depositButton"
                    ) {
                        selectedChildForTransaction = vm.childAccountCards.first?.profile
                        showDepositSheet = true
                    }

                    DashboardQuickActionButton(
                        title: "Withdraw",
                        icon: "minus.circle.fill",
                        color: Color(DesignSystemConstants.Colors.pendingAmber),
                        identifier: "dashboard.withdrawButton"
                    ) {
                        selectedChildForTransaction = vm.childAccountCards.first?.profile
                        showWithdrawSheet = true
                    }
                }
            }
        }
    }

    // MARK: - Pending Approval Queue (file-private; consolidated for Swift 6 isolation)

    @ViewBuilder
    func pendingApprovalQueueSection() -> some View {
        let pending = pendingCompletions
        if !pending.isEmpty, appState.currentProfile?.role != .hero {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("PENDING APPROVAL QUEUE") {
                    Text("\(pending.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color(DesignSystemConstants.Colors.pendingAmber))
                        )
                }

                VStack(spacing: 8) {
                    ForEach(pending, id: \.recordName) { completion in
                        pendingApprovalRow(completion)
                    }
                }
            }
            .padding(DesignSystemConstants.Padding.standard)
            .background(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.40), lineWidth: 1.5)
            )
            .id("pendingQueueAnchor")
        }
    }

    var pendingCompletions: [QuestCompletionCache] {
        cachedCompletions.filter { $0.verificationStatus == VerificationStatus.pending.rawValue }
    }

    var pendingCount: Int {
        pendingCompletions.count
    }

    @ViewBuilder
    func pendingApprovalRow(_ completion: QuestCompletionCache) -> some View {
        let heroName = cachedProfiles.first { $0.recordName == completion.completerRecordName }?.displayName ?? "Hero"
        let quest = cachedQuests.first { $0.recordName == completion.questRecordName }
        let questName = quest?.questName ?? "Quest"
        let goldAmount = quest?.goldReward ?? 0
        let scheduleLabel = quest?.scheduleTypeEnum?.displayName ?? ""

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(questName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("Submitted by \(heroName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !scheduleLabel.isEmpty {
                    Text(scheduleLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color(DesignSystemConstants.Colors.cardSurface))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { @MainActor in
                        await rejectCompletion(completion)
                    }
                } label: {
                    Text("Reject")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color(DesignSystemConstants.Colors.dangerRed).opacity(0.12))
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reject \(questName)")
                .accessibilityIdentifier("dashboard.rejectButton-\(completion.recordName)")

                Button {
                    Task { @MainActor in
                        await approveCompletion(completion)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Approve")
                        if goldAmount > 0 {
                            Text(CurrencyFormatter.string(goldAmount))
                                .font(.caption.weight(.bold).monospacedDigit())
                        }
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color(DesignSystemConstants.Colors.primaryGreen))
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Approve \(questName) for \(CurrencyFormatter.string(goldAmount))")
                .accessibilityIdentifier("dashboard.approveButton-\(completion.recordName)")
            }
        }
        .padding(DesignSystemConstants.Padding.small)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .hoverEffect(.highlight)
        .contextMenu {
            Button {
                Task { @MainActor in await approveCompletion(completion) }
            } label: {
                Label("Approve", systemImage: "checkmark.circle.fill")
            }
            Button(role: .destructive) {
                Task { @MainActor in await rejectCompletion(completion) }
            } label: {
                Label("Reject", systemImage: "xmark.circle.fill")
            }
        }
    }

    @MainActor
    func approveCompletion(_ completion: QuestCompletionCache) async {
        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: completion)
        let domainLog = completion.toQuestCompletion(zoneID: zoneID)
        guard let parent = appState.currentProfile else { return }
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
    func rejectCompletion(_ completion: QuestCompletionCache) async {
        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: completion)
        let domainLog = completion.toQuestCompletion(zoneID: zoneID)
        guard let parent = appState.currentProfile else { return }
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

    // MARK: - Weekly Summary & Payout

    @ViewBuilder
    func weeklySummarySection(summary: WeekendSummary?) -> some View {
        if let summary {
            let lootDayTitle = appState.family?.payoutDay.lootDayTitle ?? "Sunday Allowance Day"
            let isPending = summary.pendingPayoutAmount > 0
            let allRealTime = summary.heroSummaries.allSatisfy {
                ($0.profile.payoutPolicyEnum ?? appState.family?.payoutPolicy ?? .perQuest) == .realTime
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This Week's Earnings")
                            .font(.headline)
                        if allRealTime, summary.totalEarned > 0 {
                            Text("\(lootDayTitle) · Real-time Settled")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                        } else {
                            Text(isPending ? "\(lootDayTitle) · Pending Payout" : lootDayTitle)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(summary.weekOf, format: .dateTime.month().day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DashboardTotalsRow(summary: summary, isPending: isPending)

                if isPending, appState.currentProfile?.role != .hero {
                    ProcessPayoutButtonView(
                        summary: summary,
                        isProcessingPayout: isProcessingPayout,
                        onConfirmPayout: processPayout
                    )
                    .padding(.top, 4)
                }
            }
            .padding(DesignSystemConstants.Padding.standard)
            .background(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.30), lineWidth: 1)
            )
        }
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
            toastManager.show(message: "Could not create an invitation. Please try again.", type: .error)
            return
        }
        guard presentation.shareURL != nil else {
            toastManager.show(message: "Could not generate a share link for this invitation. Please try again.", type: .error)
            return
        }
        sharePresentation = presentation
    }
}
