//
//  FamilyDashboardView.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import SwiftData
import SwiftUI

struct FamilyDashboardView: View {
    @Environment(ToastManager.self) private var toastManager
    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(FamilyService.self) private var familyService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService
    @Environment(CloudKitService.self) private var cloudKitService
    @Environment(AppSyncCoordinator.self) private var appSyncCoordinator
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?

    @State private var viewModel: FamilyDashboardViewModel?
    @State private var showRolePicker: Bool = false
    @State private var sharePresentation: CloudSharePresentation?

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

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 18) {
                        if let vm = viewModel {
                            statCardsRow(vm: vm, scrollProxy: scrollProxy)
                            childAccountsSection(vm: vm)
                            depositWithdrawSection(vm: vm)
                            pendingApprovalQueueSection()
                            weeklySummarySection(summary: vm.weekSummary)
                        } else {
                            loadingPlaceholder
                        }
                    }
                    .padding(.vertical, 14)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation {
                                scrollProxy.scrollTo("pendingQueueAnchor", anchor: .top)
                            }
                            HapticsService.rigid()
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "bell.fill")
                                    .font(.body)

                                if pendingCount > 0 {
                                    Text("\(pendingCount)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(
                                            Capsule()
                                                .fill(Color(DesignSystemConstants.Colors.dangerRed))
                                        )
                                        .offset(x: 8, y: -6)
                                }
                            }
                        }
                        .accessibilityLabel("\(pendingCount) pending approvals")
                        .accessibilityIdentifier("dashboard.pendingBell")
                    }
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(appState.family?.name ?? "Guild")
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                await lifecycleCoordinator?.performManualSync()
                await viewModel?.refresh()
                await viewModel?.refreshWeekSummary()
            }
            .task {
                if viewModel == nil {
                    viewModel = FamilyDashboardViewModel(
                        questService: questService,
                        treasury: treasury,
                        achievementService: achievementService,
                        familyService: familyService,
                        appState: appState
                    )
                }
                viewModel?.subscribeToSyncEvents(appSyncCoordinator)
                rebuild()
                await viewModel?.refreshInvitations()
            }
            .onChange(of: cachedProfiles) { _, _ in
                Task {
                    rebuild()
                    await viewModel?.refreshInvitations()
                }
            }
            .onChange(of: cachedQuests) { _, _ in rebuild() }
            .onChange(of: cachedCompletions) { _, _ in rebuild() }
            .onChange(of: cachedLedgers) { _, _ in rebuild() }
            .onChange(of: cachedAllowancePeriods) { _, _ in rebuild() }
            .onChange(of: cachedAchievements) { _, _ in rebuild() }
            .onChange(of: cachedProfileAchievements) { _, _ in rebuild() }
            .onDisappear {
                viewModel?.unsubscribeFromSyncEvents(appSyncCoordinator)
            }
            .sheet(isPresented: $showRolePicker) {
                InviteRolePickerView { role in
                    await presentInviteShare(for: role)
                }
            }
            .sheet(item: $sharePresentation) { presentation in
                CloudSharingControllerWrapper(share: presentation.share, container: presentation.container)
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
    }

    private func rebuild() {
        viewModel?.rebuildLists(
            profiles: cachedProfiles,
            quests: cachedQuests,
            logs: cachedCompletions,
            ledgers: cachedLedgers,
            allowancePeriods: cachedAllowancePeriods,
            profileAchievements: cachedProfileAchievements,
            achievements: cachedAchievements
        )
    }

    // MARK: - Stat Cards

    private func statCardsRow(vm: FamilyDashboardViewModel, scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: DesignSystemConstants.Padding.medium) {
            StatCard(
                title: "FAMILY OUTFLOW",
                value: CurrencyFormatter.string(vm.familyOutflow),
                icon: "banknote.fill",
                tint: Color.gold,
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
        }
        .padding(.horizontal)
    }

    // MARK: - Child Accounts Grid

    private func childAccountsSection(vm: FamilyDashboardViewModel) -> some View {
        VStack(spacing: 12) {
            SectionHeader("CHILD ACCOUNTS") {
                if appState.currentProfile?.role == .guildMaster {
                    inviteButton
                }
            }
            .padding(.horizontal)

            if vm.childAccountCards.isEmpty {
                emptyChildrenCard
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    ForEach(vm.childAccountCards) { card in
                        childAccountCard(card, vm: vm)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func childAccountCard(_ card: ChildAccountCard, vm _: FamilyDashboardViewModel) -> some View {
        NavigationLink {
            HeroDetailView(
                hero: card.profile,
                familyRecordName: familyRecordName,
                spending: spending
            )
            .environment(questService)
            .environment(familyService)
            .environment(appState)
            .environment(appSyncCoordinator)
        } label: {
            VStack(spacing: 8) {
                // Emoji avatar with fallback to ProfileAvatarView.
                if let emoji = card.profile.avatarEmoji, !emoji.isEmpty {
                    Text(emoji)
                        .font(.system(size: 36))
                        .frame(width: 48, height: 48)
                        .background(
                            Circle()
                                .fill(Color(.tertiarySystemGroupedBackground))
                        )
                } else {
                    ProfileAvatarView(profileCache: card.profile)
                        .frame(width: 48, height: 48)
                }

                Text(card.profile.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(CurrencyFormatter.string(card.balance)) available")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(Color.gold)

                if card.pendingReviewCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text("\(card.pendingReviewCount) pending")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.15))
                    )
                }

                Text("View Screen")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(DesignSystemConstants.Padding.medium)
            .background(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View \(card.profile.displayName)'s account")
        .accessibilityIdentifier("dashboard.childAccount-\(card.profile.recordName)")
    }

    private var emptyChildrenCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.orange)
            }

            VStack(spacing: 6) {
                Text("Recruit Your Party!")
                    .font(.title3.weight(.heavy))
                Text(appState.currentProfile?.role == .guildMaster
                    ? "Your guild needs heroes to embark on quests. Tap **Invite Members** above to invite a Hero to your guild."
                    : "Your guild needs heroes to embark on quests. Ask the Guild Master to invite a Hero to your guild.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1.5)
        )
        .padding(.horizontal)
    }

    // MARK: - Deposit / Withdraw Shortcut

    @ViewBuilder
    private func depositWithdrawSection(vm: FamilyDashboardViewModel) -> some View {
        if !vm.childAccountCards.isEmpty {
            VStack(spacing: 12) {
                SectionHeader("QUICK ACTIONS")

                HStack(spacing: 12) {
                    quickActionButton(
                        title: "Deposit",
                        icon: "plus.circle.fill",
                        color: .green,
                        identifier: "dashboard.depositButton"
                    ) {
                        selectedChildForTransaction = vm.childAccountCards.first?.profile
                        showDepositSheet = true
                    }

                    quickActionButton(
                        title: "Withdraw",
                        icon: "minus.circle.fill",
                        color: .orange,
                        identifier: "dashboard.withdrawButton"
                    ) {
                        selectedChildForTransaction = vm.childAccountCards.first?.profile
                        showWithdrawSheet = true
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func quickActionButton(
        title: String,
        icon: String,
        color: Color,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .font(.subheadline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .foregroundStyle(color)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(color.opacity(0.4), lineWidth: 1)
            )
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Pending Approval Queue

    @ViewBuilder
    private func pendingApprovalQueueSection() -> some View {
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
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.40), lineWidth: 1.5)
            )
            .padding(.horizontal)
            .id("pendingQueueAnchor")
        }
    }

    private var pendingCompletions: [QuestCompletionCache] {
        cachedCompletions.filter { $0.verificationStatus == VerificationStatus.pending.rawValue }
    }

    private var pendingCount: Int {
        pendingCompletions.count
    }

    @ViewBuilder
    private func pendingApprovalRow(_ completion: QuestCompletionCache) -> some View {
        let heroName = cachedProfiles.first { $0.recordName == completion.completerRecordName }?.displayName ?? "Hero"
        let quest = cachedQuests.first { $0.recordName == completion.questRecordName }
        let questName = quest?.questName ?? "Quest"
        let goldAmount = quest?.goldReward ?? 0
        // Category chip uses schedule type as a lightweight tag.
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

                // Category chip using schedule type.
                if !scheduleLabel.isEmpty {
                    Text(scheduleLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color(.tertiarySystemGroupedBackground))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task {
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
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reject \(questName)")
                .accessibilityIdentifier("dashboard.rejectButton-\(completion.recordName)")

                Button {
                    Task {
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
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Approve \(questName) for \(CurrencyFormatter.string(goldAmount))")
                .accessibilityIdentifier("dashboard.approveButton-\(completion.recordName)")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
    }

    private func approveCompletion(_ completion: QuestCompletionCache) async {
        let zoneID = appState.familyZoneID
            ?? appState.family?.id.zoneID
            ?? completion.validatedZoneID(requestedZoneID: CKRecordZone.default().zoneID)
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

    private func rejectCompletion(_ completion: QuestCompletionCache) async {
        let zoneID = appState.familyZoneID
            ?? appState.family?.id.zoneID
            ?? completion.validatedZoneID(requestedZoneID: CKRecordZone.default().zoneID)
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
    private func weeklySummarySection(summary: WeekendSummary?) -> some View {
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
                                .foregroundStyle(.green)
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

                totalsRow(summary: summary, isPending: isPending)

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
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .strokeBorder(Color.gold.opacity(0.30), lineWidth: 1)
            )
            .padding(.horizontal)
        }
    }

    @State private var isProcessingPayout: Bool = false

    private func totalsRow(summary: WeekendSummary, isPending: Bool) -> some View {
        HStack(spacing: 12) {
            statBlock(
                icon: isPending ? "hourglass" : "banknote",
                value: CurrencyFormatter.string(isPending ? summary.pendingPayoutAmount : summary.totalEarned),
                label: isPending ? "Pending" : "Earned",
                tint: isPending ? .orange : .gold
            )
            Divider()
            statBlock(
                icon: "checkmark.circle.fill",
                value: "\(summary.totalQuestsCompleted)",
                label: "Quests",
                tint: .green
            )
            Divider()
            statBlock(
                icon: "person.2.fill",
                value: "\(summary.heroSummaries.count)",
                label: "Heroes",
                tint: .purple
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func statBlock(icon: String, value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func processPayout() async {
        isProcessingPayout = true
        defer { isProcessingPayout = false }
        guard appState.family != nil else { return }
        let zoneID = appState.familyZoneID ?? appState.family?.id.zoneID ?? CKRecordZone.default().zoneID
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

    // MARK: - Invite

    private var inviteButton: some View {
        Button {
            showRolePicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.plus")
                    .font(.caption.weight(.bold))
                Text("Invite")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay(
                        Capsule().strokeBorder(Color.gold.opacity(0.45), lineWidth: 1)
                    )
            )
        }
        .accessibilityLabel("Invite Members. Tap to invite a Hero or Co-Parent.")
        .accessibilityIdentifier("dashboard.inviteButton")
    }

    @MainActor
    private func presentInviteShare(for role: UserRole) async {
        guard let share = await viewModel?.prepareInviteShare(for: role) else {
            toastManager.show(message: "Could not create an invitation. Please try again.", type: .error)
            return
        }
        guard share.url != nil else {
            toastManager.show(message: "Could not generate a share link for this invitation. Please try again.", type: .error)
            return
        }
        sharePresentation = CloudSharePresentation(share: share, container: cloudKitService.container)
    }

    // MARK: - Loading Placeholder

    private var loadingPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "house")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
                .padding(.top, 120)
            Text("Summoning your guild…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Process Payout Button

private struct ProcessPayoutButtonView: View {
    let summary: WeekendSummary
    let isProcessingPayout: Bool
    let onConfirmPayout: () async -> Void

    @State private var showEarlyPayoutConfirm: Bool = false

    var body: some View {
        Button {
            showEarlyPayoutConfirm = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "banknote.fill")
                Text("Process Payout Now 🎁")
                    .font(.subheadline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.gold.opacity(0.20)))
            .foregroundStyle(Color.gold)
        }
        .buttonStyle(.plain)
        .disabled(isProcessingPayout)
        .accessibilityIdentifier("dashboard.processPayoutButton")
        .alert("Process Payout Now?", isPresented: $showEarlyPayoutConfirm) {
            Button("Confirm Payout", role: .destructive) {
                Task { await onConfirmPayout() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let amountStr = CurrencyFormatter.string(summary.pendingPayoutAmount)
            Text("Process payout of \(amountStr) across all heroes with completed quests? This will settle earnings for quests completed so far this week.")
        }
    }
}
