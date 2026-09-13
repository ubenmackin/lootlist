//
//  HeroHomeView.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import os
import SwiftData
import SwiftUI

/// Checklist-focused hero home: player card plus first-run checklist and immersive journey surfaces.
/// WHY second hub: ChildHubView owns balance, chores, and goal momentum; this view owns onboarding checklist and player identity so neither hub duplicates the other's transforms.
struct HeroHomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(XPService.self) private var xpService
    @Environment(GemService.self) private var gemService
    @Environment(NotificationService.self) private var notificationService
    @Environment(GoalService.self) private var goalService
    @Environment(ToastManager.self) private var toastManager: ToastManager

    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedTemplates: [QuestTemplateCache]
    @Query private var cachedProfiles: [ProfileCache]
    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]
    @Query private var cachedGemLedgers: [GemLedgerCache]
    @Query private var currentProfileRows: [ProfileCache]
    @Query private var cachedGoals: [GoalCache]
    @Query private var cachedFamilies: [FamilyCache]

    @State private var viewModel: HeroDashboardViewModel?
    @State private var showingJourneyMap = false
    @State private var checklistSheetItem: HeroChecklistCardView.ChecklistItem?

    private static let logger = Logger(category: "HeroHomeView")

    private let familyRecordName: String?

    private let profileRecordName: String?

    init(familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName

        let targetFamily = HubQueryProvider.targetFamily(familyRecordName)
        FamilyScopeValidator.validateOrFault(targetFamily: targetFamily, viewName: "HeroHomeView")
        // WHY shared provider: family+profile at store when identity resolves, family-only fallback otherwise
        // so hub surfaces never render silent-empty; secondary in-memory guards scope to the active profile.
        let targetProfile = profileRecordName.sanitizedNilIfEmpty
        let questFilter = HubQueryProvider.questFilter(family: targetFamily, profile: targetProfile)
        let completionFilter = HubQueryProvider.completionFilter(family: targetFamily, profile: targetProfile)
        let allowanceFilter = HubQueryProvider.allowanceFilter(family: targetFamily, profile: targetProfile)
        let gemLedgerFilter = HubQueryProvider.gemFilter(family: targetFamily, profile: targetProfile)
        let goalFilter = HubQueryProvider.goalFilter(family: targetFamily, profile: targetProfile)
        let currentProfileFilter = HubQueryProvider.currentProfileFilter(family: targetFamily, profile: targetProfile)
        let templateFilter = HubQueryProvider.templateFilter(family: targetFamily)
        let profileFilter = HubQueryProvider.profileFilter(family: targetFamily)
        let familyFilter = FamilyCache.recordPredicate(recordName: targetFamily)

        // WHY: stable sort — secondary recordName keeps ForEach stable after CloudKit reorders.
        _cachedQuests = Query(filter: questFilter, sort: HubQueryProvider.questSort())
        _cachedCompletions = Query(filter: completionFilter, sort: HubQueryProvider.completionSort())
        _cachedTemplates = Query(filter: templateFilter, sort: HubQueryProvider.templateSort())
        _cachedProfiles = Query(filter: profileFilter, sort: \ProfileCache.displayName)
        _cachedAllowancePeriods = Query(filter: allowanceFilter, sort: HubQueryProvider.allowanceSort())
        _cachedGemLedgers = Query(filter: gemLedgerFilter, sort: HubQueryProvider.gemSort())
        _currentProfileRows = Query(filter: currentProfileFilter, sort: \ProfileCache.displayName)
        _cachedGoals = Query(filter: goalFilter, sort: HubQueryProvider.goalSort())
        _cachedFamilies = Query(
            filter: familyFilter,
            sort: [SortDescriptor(\FamilyCache.name), SortDescriptor(\FamilyCache.recordName)]
        )
    }

    /// Queried cache row for the active hero profile. Nil when the session
    /// identity or family scope has no synced row yet, keeping rendering
    /// fail-closed instead of falling back to the session snapshot.
    private var currentProfileRow: ProfileCache? {
        ProfileRowResolver.resolve(
            rows: currentProfileRows,
            targetRecordName: profileRecordName ?? appState.currentProfile?.id.recordName
        )
    }

    /// Queried family row; nil when scope has no synced row (fail-closed rendering).
    private var cachedFamilyRow: FamilyCache? {
        cachedFamilies.first
    }

    /// Quests assigned to the active hero profile.
    private var profileQuests: [QuestCache] {
        // WHY: predicate is primary scope; secondary filter blocks cross-profile leak when identity resolves late.
        guard let name = currentProfileRow?.recordName,
              profileRecordName == nil || profileRecordName == name else { return [] }
        return cachedQuests.filter { $0.assigneeRecordName == name }
    }

    /// Completions logged by the active hero profile.
    private var profileLogs: [QuestCompletionCache] {
        // WHY: predicate is primary scope; secondary filter blocks cross-profile leak when identity resolves late.
        guard let name = currentProfileRow?.recordName,
              profileRecordName == nil || profileRecordName == name else { return [] }
        return cachedCompletions.filter { $0.completerRecordName == name }
    }

    // MARK: - Checklist

    private var hasFirstGoal: Bool {
        // WHY ViewModel-owned: checklist/wishlist agreement lives in HeroDashboardViewModel via HubQueryProvider.
        HeroDashboardViewModel.hasListedGoal(
            goals: cachedGoals,
            profileName: profileRecordName ?? currentProfileRow?.recordName
        )
    }

    private var hasCompletedFirstQuest: Bool {
        guard let viewModel else { return false }
        return viewModel.completedQuestCount > 0
    }

    private var effectiveHasSeenNotificationPrime: Bool {
        DismissalKeys.effectiveBool(
            DismissalKeys.hasSeenNotificationPrime,
            familyRecordName: familyRecordName ?? currentProfileRow?.familyRecordName ?? appState.family?.id.recordName,
            profileRecordName: profileRecordName ?? currentProfileRow?.recordName
        )
    }

    private var effectiveHasDismissedHeroChecklist: Bool {
        DismissalKeys.effectiveBool(
            DismissalKeys.hasDismissedHeroChecklist,
            familyRecordName: familyRecordName ?? currentProfileRow?.familyRecordName ?? appState.family?.id.recordName,
            profileRecordName: profileRecordName ?? currentProfileRow?.recordName
        )
    }

    private var scopedChecklistBinding: Binding<Bool> {
        DismissalKeys.scopedBinding(
            DismissalKeys.hasDismissedHeroChecklist,
            familyRecordName: familyRecordName ?? currentProfileRow?.familyRecordName ?? appState.family?.id.recordName,
            profileRecordName: profileRecordName ?? currentProfileRow?.recordName
        )
    }

    private var shouldShowChecklist: Bool {
        // Fail-closed: no row yet means cache not hydrated.
        guard !effectiveHasDismissedHeroChecklist else { return false }
        guard let row = currentProfileRow else { return false }
        // WHY utility-first: gate on non-parent role, not RPG chrome; immersive RPG surfaces stay hidden per ARCHITECTURE §1.
        let isChild = (row.roleEnum?.isParent ?? true) == false
        guard isChild else { return false }
        guard viewModel != nil else { return false }
        let pending = !effectiveHasSeenNotificationPrime
        let isDefault = splitIsDefault(for: row)
        let hasQuest = hasCompletedFirstQuest
        let hasGoal = hasFirstGoal
        let allDone = !pending && !isDefault && hasQuest && hasGoal
        return !allDone
    }

    /// Single helper for the default-split check so `shouldShowChecklist` and
    /// `scrollContent` share one computation path instead of diverging overloads.
    private func splitIsDefault(for row: ProfileCache) -> Bool {
        HeroDashboardViewModel.splitIsDefault(spend: row.splitPercentSpend, short: row.splitPercentShort, long: row.splitPercentLong)
    }

    /// Writes the scoped key (family+profile isolation) so completion here never leaks into another family's prime gate.
    private func markNotificationPrimeSeen() {
        let family = familyRecordName ?? currentProfileRow?.familyRecordName ?? appState.family?.id.recordName
        let profile = profileRecordName ?? currentProfileRow?.recordName
        DismissalStore.markSeen(DismissalKeys.hasSeenNotificationPrime, familyRecordName: family, profileRecordName: profile)
    }

    /// One-time legacy promotion for dismissal gates, run from .task so view bodies stay pure.
    private func migrateDismissals() {
        let family = familyRecordName ?? currentProfileRow?.familyRecordName ?? appState.family?.id.recordName
        let profile = profileRecordName ?? currentProfileRow?.recordName
        DismissalKeys.migrate(DismissalKeys.hasSeenNotificationPrime, familyRecordName: family, profileRecordName: profile)
        DismissalKeys.migrate(DismissalKeys.hasDismissedHeroChecklist, familyRecordName: family, profileRecordName: profile)
    }

    var body: some View {
        NavigationStack {
            heroSurface
        }
        // WHY: view identity tracks family+profile so @Query predicates (init-captured) are recreated on scope switch; defensive filter in rebuild() is secondary guard.
        .id("\(familyRecordName ?? "")-\(profileRecordName ?? "")")
    }

    // MARK: - Subviews

    /// WHY split: keeping the presentation modifiers on their own expression lets the type-checker solve
    /// the scroll surface and the observer chain independently instead of as one nested generic.
    private var heroSurface: some View {
        heroScrollSurface
            .background(Color(DesignSystemConstants.Colors.background))
            .scrollContentBackground(.hidden)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                toolbarContent
            }
            .fullScreenCover(isPresented: $showingJourneyMap) {
                journeyMapCover
            }
            .sheet(item: $checklistSheetItem) { item in
                checklistSheet(for: item)
            }
    }

    /// WHY split: lifecycle and query-change observers are grouped away from presentation modifiers so
    /// neither chain has to be inferred together.
    private var heroScrollSurface: some View {
        heroObservedScroll
            .onChange(of: cachedAllowancePeriods) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedGoals) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: currentProfileRows) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedGemLedgers) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedFamilies) { _, _ in
                rebuildViewModel()
            }
    }

    /// WHY split: the scroll view, its lifecycle hook, and the leading observers form one expression so
    /// the remaining observer group on `heroScrollSurface` stays a shallow modifier chain.
    private var heroObservedScroll: some View {
        ScrollView {
            scrollContent
        }
        .task {
            migrateDismissals()
            ensureViewModel()
        }
        .onChange(of: cachedQuests) { _, _ in
            rebuildViewModel()
        }
        .onChange(of: cachedCompletions) { _, _ in
            rebuildViewModel()
        }
        .onChange(of: cachedTemplates) { _, _ in
            rebuildViewModel()
        }
        .onChange(of: cachedProfiles) { _, _ in
            rebuildViewModel()
        }
    }

    private var scrollContent: some View {
        VStack(spacing: DesignSystemConstants.Padding.standard) {
            checklistCard

            DailyLoginBannerView(profileRow: currentProfileRow, compactMode: true)

            playerCard

            // Legacy RPG chrome hidden when FeatureFlags.rpgImmersive is false.
            if FeatureFlags.rpgImmersive, let row = currentProfileRow {
                journeyMapCard(row: row)
                mascotBanner(row: row)
            }
        }
        .padding(.horizontal, DesignSystemConstants.Padding.standard)
        .padding(.bottom, DesignSystemConstants.Padding.standard - 4)
    }

    /// WHY split: isolates the checklist initializer's overload resolution and optional row unwrap from
    /// the surrounding stack so neither expression compounds the other's inference.
    @ViewBuilder
    private var checklistCard: some View {
        if shouldShowChecklist, let row = currentProfileRow {
            let splitIsDefault = splitIsDefault(for: row)
            HeroChecklistCardView(
                profileRow: row,
                pendingNotification: !effectiveHasSeenNotificationPrime,
                splitIsDefault: splitIsDefault,
                hasCompletedFirstQuest: hasCompletedFirstQuest,
                hasFirstGoal: hasFirstGoal,
                onAction: handleChecklistAction,
                hasDismissedHeroChecklist: scopedChecklistBinding
            )
        }
    }

    @ViewBuilder
    private func journeyMapCard(row: ProfileCache) -> some View {
        let state = JourneyService.journeyState(profileCache: row, xpService: xpService)
        JourneyMapCardView(journeyState: state) {
            showingJourneyMap = true
        }
    }

    private func mascotBanner(row: ProfileCache) -> some View {
        MascotBannerView(
            profileCache: row,
            quests: profileQuests,
            completions: profileLogs,
            templatesByID: SpecificDaysHelper.templatesByID(cachedTemplates),
            showBonusCard: true
        )
    }

    @ViewBuilder
    private var journeyMapCover: some View {
        if let row = currentProfileRow {
            let state = JourneyService.journeyState(profileCache: row, xpService: xpService)
            JourneyMapView(journeyState: state, profileCache: row)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Legacy RPG chrome hidden when FeatureFlags.rpgImmersive is false.
        if FeatureFlags.rpgImmersive {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    GemShopView(familyRecordName: familyRecordName, profileRecordName: profileRecordName)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "diamond.fill")
                            .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                        Text(gemBalanceText)
                            .font(.subheadline.bold())
                            .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                    }
                }
                .accessibilityLabel(gemShopAccessibilityLabel)
            }
        }
    }

    private var gemBalanceText: String {
        gemsBalance.map(String.init) ?? "–"
    }

    private var gemShopAccessibilityLabel: String {
        gemsBalance.map { "Gem Shop, \($0) gems available" } ?? "Gem Shop, gem balance unavailable"
    }

    // MARK: - Integrated Player Card (focused section)

    @ViewBuilder
    private var playerCard: some View {
        if let row = currentProfileRow {
            HeroHomePlayerCardView(
                row: row,
                progress: xpService.levelProgress(profileCache: row),
                pennies: viewModel?.earnedThisWeek ?? 0,
                streak: row.dailyLoginStreakDays,
                shields: row.streakShields,
                completed: viewModel?.completedQuestCount ?? 0,
                total: profileQuests.count,
                // WHY cache-first family: pill renders the queried row so display never reads session domain.
                familyName: cachedFamilyRow?.name
            )
        }
    }

    // MARK: - Helpers

    private var gemsBalance: Int? {
        guard let row = currentProfileRow else { return nil }
        let targetRecordName = row.recordName
        if let cached = HeroDashboardViewModel.cachedGemTotal(ledgers: cachedGemLedgers, profileName: targetRecordName) {
            return cached
        }
        // WHY row-first family: the cache row owns scope with param fallback, session only bridges bootstrap.
        let rowFamily = row.familyRecordName.trimmingCharacters(in: .whitespacesAndNewlines)
        let family: String? = rowFamily.isEmpty ? (familyRecordName ?? appState.family?.id.recordName) : rowFamily
        guard let family, !family.isEmpty else { return nil }
        do {
            return try gemService.balance(for: targetRecordName, familyRecordName: family)
        } catch {
            Self.logger.warning("HeroHomeView.gemsBalance: failed to fetch gem balance: \(error, privacy: .private)")
            return 0
        }
    }

    private func ensureViewModel() {
        ViewLifecycle.ensureAndRebuild(&viewModel, factory: {
            HeroDashboardViewModel(appState: appState)
        }, rebuild: { vm in rebuildViewModel(vm) })
    }

    private func rebuildViewModel(_ vm: HeroDashboardViewModel? = nil) {
        appState.updateCurrentProfileFromCache()
        guard let targetVM = vm ?? viewModel else { return }
        guard let currentName = currentProfileRow?.recordName else { return }

        // WHY: predicate is primary profile scope; secondary in-memory filter guards stale identity when view is not recreated on profile switch.
        let quests = cachedQuests.filter { $0.assigneeRecordName == currentName }
        let logs = cachedCompletions.filter { $0.completerRecordName == currentName }
        let periods = cachedAllowancePeriods.filter { $0.profileRecordName == currentName }
        targetVM.rebuildLists(quests: quests, logs: logs, templates: cachedTemplates, allowancePeriods: periods, viewerRow: currentProfileRow, familyRow: cachedFamilyRow)
    }

    // MARK: - Checklist Actions

    private func handleChecklistAction(_ item: HeroChecklistCardView.ChecklistItem) {
        HapticsService.lightImpact()
        switch item {
        case .notifications, .buckets, .firstGoal, .firstQuest:
            checklistSheetItem = item
        }
    }

    @ViewBuilder
    private func checklistSheet(for item: HeroChecklistCardView.ChecklistItem) -> some View {
        switch item {
        case .notifications:
            checklistNotificationSheet
        case .buckets:
            SavingsSplitView(
                familyRecordName: familyRecordName ?? currentProfileRow?.familyRecordName,
                profileRecordName: profileRecordName ?? currentProfileRow?.recordName
            )
        case .firstGoal:
            GoalEditorSheet(
                familyRecordName: familyRecordName ?? currentProfileRow?.familyRecordName,
                profileRecordName: profileRecordName ?? currentProfileRow?.recordName
            ) { draft in
                try await saveChecklistGoal(draft)
            }
        case .firstQuest:
            checklistFirstQuestSheet
        }
    }

    private var checklistNotificationSheet: some View {
        HeroHomeNotificationPrimeSheetView(
            onEnable: {
                Task {
                    HapticsService.lightImpact()
                    do {
                        _ = try await notificationService.enableNotificationsAfterPrime()
                    } catch {
                        Self.logger.debug("Notification prime authorization failed: \(error, privacy: .private)")
                    }
                    markNotificationPrimeSeen()
                    checklistSheetItem = nil
                }
            },
            onSkip: {
                HapticsService.lightImpact()
                markNotificationPrimeSeen()
                checklistSheetItem = nil
            },
            onClose: { checklistSheetItem = nil }
        )
    }

    private var checklistFirstQuestSheet: some View {
        HeroHomeFirstQuestSheetView(
            onClose: { checklistSheetItem = nil },
            onAcknowledge: {
                HapticsService.lightImpact()
                checklistSheetItem = nil
            }
        )
    }

    @MainActor
    private func saveChecklistGoal(_ draft: GoalDraft) async throws {
        guard let family = appState.family, let zoneID = appState.familyZoneID else {
            throw FamilyServiceError.unauthorized
        }
        let targetName = profileRecordName ?? currentProfileRow?.recordName
        // WHY: mutation actor derives from the cache row so goal creation never reads session domain state.
        guard let row = currentProfileRow, row.recordName == targetName else {
            throw FamilyServiceError.unauthorized
        }
        let profile = row.toProfile(zoneID: zoneID)
        do {
            _ = try await goalService.createGoal(
                name: draft.name,
                category: draft.category,
                emojiIcon: draft.emojiIcon,
                targetAmountPennies: draft.targetAmountPennies,
                bucketKind: draft.bucketKind,
                targetDate: draft.targetDate,
                linkURL: draft.linkURL,
                imageURL: draft.imageURL,
                for: profile,
                family: family
            )
            HapticsService.lightImpact()
            checklistSheetItem = nil
        } catch {
            toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
            throw error
        }
    }
}
