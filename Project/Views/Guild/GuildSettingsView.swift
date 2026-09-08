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
    private let logger = Logger(category: "GuildSettings")

    @Environment(ToastManager.self) private var toastManager
    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService
    @Environment(FamilyService.self) private var familyService
    @Environment(AppSyncCoordinator.self) private var appSyncCoordinator
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?
    @Environment(CacheService.self) private var cacheService: CacheService?

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
    @Query private var cachedTemplates: [QuestTemplateCache]
    @Query private var currentProfileRows: [ProfileCache]

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
    @State private var ledgerHistoryLimit: Int = 50
    @State private var ledgerHistoryMonth: Date = .init()
    @State private var historyMinAmountText: String = ""
    @FocusState private var isHistoryAmountFocused: Bool

    private let familyRecordName: String?
    private let profileRecordName: String?

    init(familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName
        let targetFamily = familyRecordName ?? ""
        FamilyScopeValidator.assertNonEmpty(targetFamily: targetFamily, viewName: "GuildSettingsView")
        let profileFilter = ProfileCache.familyPredicate(familyRecordName: targetFamily)
        let questFilter = QuestCache.familyPredicate(familyRecordName: targetFamily)
        let completionFilter = QuestCompletionCache.familyPredicate(familyRecordName: targetFamily)
        let ledgerFilter = LedgerEntryCache.familyPredicate(familyRecordName: targetFamily)
        let allowanceFilter = AllowancePeriodCache.familyPredicate(familyRecordName: targetFamily)
        let achievementFilter = AchievementCache.familyPredicate(familyRecordName: targetFamily)
        let profileAchievementFilter = ProfileAchievementCache.familyPredicate(familyRecordName: targetFamily)
        let goalFilter = GoalCache.familyPredicate(familyRecordName: targetFamily)
        let gemLedgerFilter = GemLedgerCache.familyPredicate(familyRecordName: targetFamily)
        let rewardEventFilter = RewardEventCache.familyPredicate(familyRecordName: targetFamily)
        let templateFilter = QuestTemplateCache.familyPredicate(familyRecordName: targetFamily)

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
        _cachedTemplates = Query(filter: templateFilter, sort: [SortDescriptor(\QuestTemplateCache.name), SortDescriptor(\QuestTemplateCache.recordName)])
        // WHY: single-row scope keeps role and displayName cache-derived instead of session-derived.
        _currentProfileRows = Query(
            filter: HubQueryProvider.currentProfileFilter(family: targetFamily, profile: profileRecordName),
            sort: HubQueryProvider.currentProfileSort()
        )
    }

    /// Queried cache row for the active viewer; nil when scope has no synced row (fail-closed rendering).
    private var currentProfileRow: ProfileCache? {
        // WHY: resolver keeps empty-scope fail-closed while session identity bridges bootstrap before the param propagates.
        HubQueryProvider.resolveViewerRow(
            rows: currentProfileRows,
            profileRecordName: profileRecordName,
            fallbackRecordName: appState.currentProfile?.id.recordName
        )
    }

    /// Viewer role derived from cache so gating never reads session domain state.
    private var viewerIsGuildMaster: Bool {
        currentProfileRow?.roleEnum == .guildMaster
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
                .onChange(of: currentProfileRows) { _, _ in
                    rebuildViewModel()
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
        // WHY: view identity tracks family+profile so @Query predicates (init-captured) are recreated on scope switch.
        .id("\(familyRecordName ?? "")-\(profileRecordName ?? "")")
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
            achievements: cachedAchievements,
            templates: cachedTemplates
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
            isRoleTransferConfirmPresented: $isRoleTransferConfirmPresented,
            familyRecordName: familyRecordName,
            profileRecordName: profileRecordName ?? currentProfileRow?.recordName
        )
        if viewerIsGuildMaster {
            GuildPayoutDefaultsSectionView(isPayoutPolicyExpanded: $isPayoutPolicyExpanded)
        }
        ledgerHistorySection
        GuildDangerZoneSectionView(isSigningOut: $isSigningOut)
    }

    /// WHY month window rides WeekMath: history shares the store query's UTC month derivation so paging cannot drift.
    private var monthWindowedLedgers: [LedgerEntryCache] {
        // WHY touch count: keeps view subscribed so indexed refetch rides @Query refresh.
        _ = cachedLedgers.count
        // WHY family-only in-memory month: no family+date index exists; DB narrows by family via base index, month filters in-memory.
        let store = cacheService ?? appState.cacheService
        let family = familyRecordName ?? appState.family?.id.recordName ?? ""
        guard !family.isEmpty, let store else { return [] }
        // WHY family-wide history: profile stays nil so history stays family-wide; amount threshold stays a display filter.
        let page = store.fetchLedgerEntriesForMonth(familyRecordName: family, monthContaining: ledgerHistoryMonth, fetchLimit: ledgerHistoryLimit)
        // WHY recordName tie-breaker: stabilizes ForEach order on the small indexed page.
        return page.sorted {
            if $0.date != $1.date {
                $0.date > $1.date
            } else {
                $0.recordName < $1.recordName
            }
        }
    }

    private var monthLedgerHistory: [LedgerEntryCache] {
        Array(monthLedgerFiltered.prefix(ledgerHistoryLimit))
    }

    private var monthLedgerFiltered: [LedgerEntryCache] {
        // WHY amount gate stays in-memory: the threshold is a display filter, never part of the indexed store predicate.
        let threshold = CurrencyFormatter.pennies(from: historyMinAmountText) ?? 0
        guard threshold > 0 else { return monthWindowedLedgers }
        return monthWindowedLedgers.filter { abs($0.amount) >= threshold }
    }

    private var ledgerHistorySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent Activity")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    shiftHistoryMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityIdentifier("settings.history.prevMonth")
                Text(ledgerHistoryMonth.formatted(.dateTime.month(.abbreviated).year()))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    shiftHistoryMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityIdentifier("settings.history.nextMonth")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            TextField("Minimum amount", text: $historyMinAmountText)
                .keyboardType(.decimalPad)
                .focused($isHistoryAmountFocused)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.history.minAmount")
                .onChange(of: historyMinAmountText) { _, _ in ledgerHistoryLimit = 50 }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

            if monthLedgerHistory.isEmpty {
                Text("No activity this month.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            } else {
                ForEach(monthLedgerHistory, id: \.recordName) { entry in
                    ledgerHistoryRow(entry)
                    Divider()
                }
                // WHY page-full gate: store page is already limited so prefix cannot reveal more; full page means maybe more.
                if monthWindowedLedgers.count >= ledgerHistoryLimit {
                    Button("Show more (\(monthLedgerHistory.count) shown)") {
                        ledgerHistoryLimit += 50
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    .accessibilityIdentifier("settings.history.showMore")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .padding(.horizontal)
        .decimalPadDoneToolbar(isFocused: $isHistoryAmountFocused)
    }

    private func ledgerHistoryRow(_ entry: LedgerEntryCache) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.entryDescription)
                    .font(.subheadline)
                Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(CurrencyFormatter.string(pennies: entry.amount))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(entry.amount >= 0 ? Color(DesignSystemConstants.Colors.primaryGreen) : Color(DesignSystemConstants.Colors.dangerRed))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func shiftHistoryMonth(by delta: Int) {
        // WHY paging resets on window change: a new month starts from its first page.
        ledgerHistoryMonth = Calendar.iso8601UTC.date(byAdding: .month, value: delta, to: ledgerHistoryMonth) ?? ledgerHistoryMonth
        ledgerHistoryLimit = 50
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
                if viewerIsGuildMaster {
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

            if viewerIsGuildMaster {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Guild Invitations")
                                .font(.subheadline.weight(.semibold))
                            Text("Pick a role, then add that person by email or phone in the share sheet")
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
                        .accessibilityHint("Pick a role, then add a person by email or phone in the share sheet")
                    }
                    // WHY invites stay private until a named participant is added, so the link alone must not read as access.
                    Text("Invites are private — Copy Link alone grants no access. Tap Add People and enter a specific email or phone number.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
        // WHY: mutation actor derives from the cache row so role transfer never reads session domain state.
        guard let row = currentProfileRow else { return }
        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: newOwner)
        let current = row.toProfile(zoneID: zoneID)
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
