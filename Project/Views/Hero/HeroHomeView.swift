//
//  HeroHomeView.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import os
import SwiftData
import SwiftUI

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

    @State private var viewModel: HeroDashboardViewModel?
    @State private var showingJourneyMap = false
    @State private var checklistSheetItem: HeroChecklistCardView.ChecklistItem?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "HeroHomeView")

    private let familyRecordName: String?

    private let profileRecordName: String?

    init(familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName

        let targetFamily = familyRecordName ?? ""
        FamilyScopeValidator.validateOrFault(targetFamily: targetFamily, viewName: "HeroHomeView")
        // WHY: predicate pushdown — family+profile at store when identity resolves, family-only fallback otherwise
        // so hub surfaces never render silent-empty; secondary in-memory guards scope to the active profile.
        let templateFilter = #Predicate<QuestTemplateCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let profileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }
        if let targetProfile = profileRecordName.sanitizedNilIfEmpty {
            let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.assigneeRecordName == targetProfile && $0.isActive == true }
            let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily && $0.completerRecordName == targetProfile }
            let allowanceFilter = #Predicate<AllowancePeriodCache> { $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile }
            let gemLedgerFilter = #Predicate<GemLedgerCache> { $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile }
            let goalFilter = #Predicate<GoalCache> { $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile }
            let currentProfileFilter = #Predicate<ProfileCache> {
                $0.recordName == targetProfile && $0.familyRecordName == targetFamily
            }

            // WHY: stable sort — secondary recordName keeps ForEach stable after CloudKit reorders.
            _cachedQuests = Query(
                filter: questFilter,
                sort: [SortDescriptor(\QuestCache.weekOf, order: .reverse), SortDescriptor(\QuestCache.recordName)]
            )
            _cachedCompletions = Query(
                filter: completionFilter,
                sort: [SortDescriptor(\QuestCompletionCache.completedDate, order: .reverse), SortDescriptor(\QuestCompletionCache.recordName)]
            )
            _cachedTemplates = Query(
                filter: templateFilter,
                sort: \QuestTemplateCache.name
            )
            _cachedProfiles = Query(
                filter: profileFilter,
                sort: \ProfileCache.displayName
            )
            _cachedAllowancePeriods = Query(
                filter: allowanceFilter,
                sort: [SortDescriptor(\AllowancePeriodCache.weekOf, order: .reverse), SortDescriptor(\AllowancePeriodCache.recordName)]
            )
            _cachedGemLedgers = Query(
                filter: gemLedgerFilter,
                sort: [SortDescriptor(\GemLedgerCache.createdAt, order: .reverse), SortDescriptor(\GemLedgerCache.recordName)]
            )
            _currentProfileRows = Query(
                filter: currentProfileFilter,
                sort: \ProfileCache.displayName
            )
            _cachedGoals = Query(
                filter: goalFilter,
                sort: [SortDescriptor(\GoalCache.createdAt), SortDescriptor(\GoalCache.recordName)]
            )
        } else {
            let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
            let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily }
            let allowanceFilter = #Predicate<AllowancePeriodCache> { $0.familyRecordName == targetFamily }
            let gemLedgerFilter = #Predicate<GemLedgerCache> { $0.familyRecordName == targetFamily }
            let goalFilter = #Predicate<GoalCache> { $0.familyRecordName == targetFamily }
            let currentProfileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }

            // WHY: stable sort — secondary recordName keeps ForEach stable after CloudKit reorders.
            _cachedQuests = Query(
                filter: questFilter,
                sort: [SortDescriptor(\QuestCache.weekOf, order: .reverse), SortDescriptor(\QuestCache.recordName)]
            )
            _cachedCompletions = Query(
                filter: completionFilter,
                sort: [SortDescriptor(\QuestCompletionCache.completedDate, order: .reverse), SortDescriptor(\QuestCompletionCache.recordName)]
            )
            _cachedTemplates = Query(
                filter: templateFilter,
                sort: \QuestTemplateCache.name
            )
            _cachedProfiles = Query(
                filter: profileFilter,
                sort: \ProfileCache.displayName
            )
            _cachedAllowancePeriods = Query(
                filter: allowanceFilter,
                sort: [SortDescriptor(\AllowancePeriodCache.weekOf, order: .reverse), SortDescriptor(\AllowancePeriodCache.recordName)]
            )
            _cachedGemLedgers = Query(
                filter: gemLedgerFilter,
                sort: [SortDescriptor(\GemLedgerCache.createdAt, order: .reverse), SortDescriptor(\GemLedgerCache.recordName)]
            )
            _currentProfileRows = Query(
                filter: currentProfileFilter,
                sort: \ProfileCache.displayName
            )
            _cachedGoals = Query(
                filter: goalFilter,
                sort: [SortDescriptor(\GoalCache.createdAt), SortDescriptor(\GoalCache.recordName)]
            )
        }
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

    /// Quests assigned to the active hero profile.
    private var profileQuests: [QuestCache] {
        // WHY: defensive — predicate is source of truth; guards against stale identity drift.
        guard let name = appState.currentProfile?.id.recordName,
              profileRecordName == nil || profileRecordName == name else { return [] }
        return cachedQuests
    }

    /// Completions logged by the active hero profile.
    private var profileLogs: [QuestCompletionCache] {
        // WHY: defensive — store is source of truth; guards against stale identity drift.
        guard let name = appState.currentProfile?.id.recordName,
              profileRecordName == nil || profileRecordName == name else { return [] }
        return cachedCompletions
    }

    // MARK: - Checklist

    private var hasFirstGoal: Bool {
        // WHY shared predicate: the checklist and the wishlist must agree on what counts as a goal; completed rows still count.
        if let targetName = profileRecordName ?? appState.currentProfile?.id.recordName {
            return cachedGoals.contains { $0.profileRecordName == targetName && $0.isListedGoal }
        }
        return cachedGoals.contains(where: \.isListedGoal)
    }

    private var hasCompletedFirstQuest: Bool {
        guard let viewModel else { return false }
        return viewModel.completedQuestCount > 0
    }

    private var effectiveHasSeenNotificationPrime: Bool {
        DismissalKeys.effectiveBool(
            DismissalKeys.hasSeenNotificationPrime,
            familyRecordName: familyRecordName ?? appState.family?.id.recordName,
            profileRecordName: profileRecordName ?? appState.currentProfile?.id.recordName
        )
    }

    private var effectiveHasDismissedHeroChecklist: Bool {
        DismissalKeys.effectiveBool(
            DismissalKeys.hasDismissedHeroChecklist,
            familyRecordName: familyRecordName ?? appState.family?.id.recordName,
            profileRecordName: profileRecordName ?? appState.currentProfile?.id.recordName
        )
    }

    private var scopedChecklistBinding: Binding<Bool> {
        DismissalKeys.scopedBinding(
            DismissalKeys.hasDismissedHeroChecklist,
            familyRecordName: familyRecordName ?? appState.family?.id.recordName,
            profileRecordName: profileRecordName ?? appState.currentProfile?.id.recordName
        )
    }

    private var shouldShowChecklist: Bool {
        // Fail-closed: no row yet means cache not hydrated.
        guard !effectiveHasDismissedHeroChecklist else { return false }
        guard let row = currentProfileRow else { return false }
        // WHY utility-first: gate on non-parent role, not RPG chrome; immersive RPG surfaces stay hidden per ARCHITECTURE §1.
        let isChild = (row.roleEnum?.isParent ?? appState.currentProfile?.role.isParent ?? true) == false
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
        BucketService.isDefaultSplit(spend: row.splitPercentSpend, short: row.splitPercentShort, long: row.splitPercentLong)
    }

    /// Writes the scoped key (family+profile isolation) so completion here never leaks into another family's prime gate.
    private func markNotificationPrimeSeen() {
        let family = familyRecordName ?? appState.family?.id.recordName
        let profile = profileRecordName ?? appState.currentProfile?.id.recordName
        DismissalStore.markSeen(DismissalKeys.hasSeenNotificationPrime, familyRecordName: family, profileRecordName: profile)
    }

    /// One-time legacy promotion for dismissal gates, run from .task so view bodies stay pure.
    private func migrateDismissals() {
        let family = familyRecordName ?? appState.family?.id.recordName
        let profile = profileRecordName ?? appState.currentProfile?.id.recordName
        DismissalKeys.migrate(DismissalKeys.hasSeenNotificationPrime, familyRecordName: family, profileRecordName: profile)
        DismissalKeys.migrate(DismissalKeys.hasDismissedHeroChecklist, familyRecordName: family, profileRecordName: profile)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                scrollContent
            }
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
            .onChange(of: cachedAllowancePeriods) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedGoals) { _, _ in
                rebuildViewModel()
            }
        }
        // WHY: view identity tracks profileRecordName so @Query predicates (init-captured) are recreated on profile switch; defensive filter in rebuild() is secondary guard.
        .id(profileRecordName)
    }

    // MARK: - Subviews

    private var scrollContent: some View {
        VStack(spacing: DesignSystemConstants.Padding.standard) {
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

            DailyLoginBannerView(compactMode: true)

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

    // MARK: - Integrated Player Card

    @ViewBuilder
    private var playerCard: some View {
        if let row = currentProfileRow {
            let progress = xpService.levelProgress(profileCache: row)
            let earned = viewModel?.earnedThisWeek ?? 0
            let streak = row.dailyLoginStreakDays
            let shields = row.streakShields
            let completed = viewModel?.completedQuestCount ?? 0
            let total = profileQuests.count

            VStack(spacing: 12) {
                playerCardTopRow(row: row, progress: progress)

                Divider()
                    .overlay(Color.secondary.opacity(0.15))

                playerCardStatsRow(
                    earned: earned,
                    streak: streak,
                    shields: shields,
                    completed: completed,
                    total: total
                )
            }
            .padding(DesignSystemConstants.Padding.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private func playerCardTopRow(row: ProfileCache, progress: LevelProgress) -> some View {
        HStack(spacing: 12) {
            ProfileAvatarView(profileCache: row)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(row.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    // Legacy RPG chrome hidden when FeatureFlags.rpgImmersive is false.
                    if FeatureFlags.rpgImmersive {
                        Text("Lv. \(progress.currentLevel)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color(DesignSystemConstants.Colors.accentBlue))
                            )
                    }

                    Spacer(minLength: 0)

                    if let familyName = appState.family?.name, !familyName.isEmpty {
                        familyNamePill(familyName)
                    }
                }

                xpProgressBar(progress: progress.progress)
            }
        }
    }

    private func xpProgressBar(progress: Double) -> some View {
        GeometryReader { geo in
            let rawWidth = geo.size.width
            let trackWidth: CGFloat = (rawWidth.isFinite && rawWidth > 0) ? rawWidth : 0
            let rawProgress = CGFloat(progress)
            let safeProgress: CGFloat = (rawProgress.isFinite && rawProgress > 0) ? min(rawProgress, 1) : 0
            let fillWidth = trackWidth * safeProgress
            let safeFillWidth: CGFloat = (fillWidth.isFinite && fillWidth > 0) ? fillWidth : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(DesignSystemConstants.Colors.background))

                Capsule()
                    .fill(LinearGradient(
                        colors: [Color(DesignSystemConstants.Colors.accentBlue), Color(DesignSystemConstants.Colors.accentBlue)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: safeFillWidth)
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: progress)
            }
        }
        .frame(height: 6)
    }

    private func playerCardStatsRow(
        earned: Double,
        streak: Int,
        shields: Int,
        completed: Int,
        total: Int
    ) -> some View {
        HStack(spacing: 0) {
            // Weekly Haul
            HStack(spacing: 6) {
                Image(systemName: "banknote.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                VStack(alignment: .leading, spacing: 1) {
                    Text("This Week")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(CurrencyFormatter.string(earned))
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                }
            }

            Spacer()

            // Streak & Shields
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Streak")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("\(streak)d")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        if shields > 0 {
                            Text("🛡️\(shields)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                        }
                    }
                }
            }

            Spacer()

            // Quests Progress
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.subheadline)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Quests")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(completed)/\(total)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private func familyNamePill(_ name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "shield.fill")
                .font(.caption2)
            Text(name)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.12))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.35), lineWidth: 1)
        )
        .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
    }

    // MARK: - Helpers

    private var gemsBalance: Int? {
        guard let profile = appState.currentProfile else { return nil }
        let targetRecordName = profile.id.recordName
        let matching = cachedGemLedgers.filter { $0.profileRecordName == targetRecordName }
        if !matching.isEmpty {
            return matching.reduce(0) { $0 + $1.amount }
        }
        let family = appState.family?.id.recordName ?? profile.family.recordID.recordName
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
        guard let currentName = appState.currentProfile?.id.recordName else { return }

        // WHY: predicate is primary profile scope; secondary in-memory filter guards stale identity when view is not recreated on profile switch.
        let quests = cachedQuests.filter { $0.assigneeRecordName == currentName }
        let logs = cachedCompletions.filter { $0.completerRecordName == currentName }
        let periods = cachedAllowancePeriods.filter { $0.profileRecordName == currentName }
        targetVM.rebuildLists(quests: quests, logs: logs, templates: cachedTemplates, allowancePeriods: periods)
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
                familyRecordName: familyRecordName,
                profileRecordName: profileRecordName ?? appState.currentProfile?.id.recordName
            )
        case .firstGoal:
            GoalEditorSheet(
                familyRecordName: familyRecordName,
                profileRecordName: profileRecordName ?? appState.currentProfile?.id.recordName
            ) { draft in
                try await saveChecklistGoal(draft)
            }
        case .firstQuest:
            checklistFirstQuestSheet
        }
    }

    private var checklistNotificationSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                NotificationPrimeCard()
                    .padding(.top, 32)
                    .padding(.horizontal, 24)

                Button {
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
                } label: {
                    Text("Turn On")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(DesignSystemConstants.Colors.accentBlue))
                .padding(.horizontal, 24)
                .accessibilityIdentifier("heroChecklist.enableNotificationsButton")

                Button {
                    HapticsService.lightImpact()
                    markNotificationPrimeSeen()
                    checklistSheetItem = nil
                } label: {
                    Text("Maybe Later")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("heroChecklist.skipNotificationsButton")

                Spacer(minLength: 0)
            }
            .padding(.vertical, 16)
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { checklistSheetItem = nil }
                }
            }
        }
    }

    private var checklistFirstQuestSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(FlavorTextProvider.questCompleteHint)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.top, 32)
                    .padding(.horizontal, 24)
                Text(FlavorTextProvider.questHelpHowTo)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
                Button {
                    HapticsService.lightImpact()
                    checklistSheetItem = nil
                } label: {
                    Text("Got it!")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(DesignSystemConstants.Colors.primaryGreen))
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationTitle("First Quest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { checklistSheetItem = nil }
                }
            }
        }
    }

    @MainActor
    private func saveChecklistGoal(_ draft: GoalDraft) async throws {
        guard let family = appState.family, let zoneID = appState.familyZoneID else {
            throw FamilyServiceError.unauthorized
        }
        let targetName = profileRecordName ?? appState.currentProfile?.id.recordName
        let profile: Profile
        if let row = currentProfileRow, row.recordName == targetName {
            profile = row.toProfile(zoneID: zoneID)
        } else if let current = appState.currentProfile {
            profile = current
        } else {
            throw FamilyServiceError.unauthorized
        }
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
