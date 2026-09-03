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

    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedTemplates: [QuestTemplateCache]
    @Query private var cachedProfiles: [ProfileCache]
    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]
    @Query private var currentProfileRows: [ProfileCache]

    @State private var viewModel: HeroDashboardViewModel?
    @State private var showingJourneyMap = false

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "HeroHomeView")

    private let familyRecordName: String?

    private let profileRecordName: String?

    init(familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName

        let targetFamily = familyRecordName ?? ""
        let targetProfile = profileRecordName ?? ""
        FamilyScopeValidator.validateOrFault(targetFamily: targetFamily, viewName: "HeroHomeView")
        // WHY: predicate pushdown — filter by family+profile at store; avoids family-wide scan.
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.assigneeRecordName == targetProfile && $0.isActive == true }
        // WHY: hero-scoped completions — store filters by completer to avoid family-wide scan.
        let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily && $0.completerRecordName == targetProfile }
        let templateFilter = #Predicate<QuestTemplateCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let profileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }
        let allowanceFilter = #Predicate<AllowancePeriodCache> { $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile }
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
        _currentProfileRows = Query(
            filter: currentProfileFilter,
            sort: \ProfileCache.displayName
        )
    }

    /// Queried cache row for the active hero profile. Nil when the session
    /// identity or family scope has no synced row yet, keeping rendering
    /// fail-closed instead of falling back to the session snapshot.
    private var currentProfileRow: ProfileCache? {
        currentProfileRows.first
    }

    /// Quests assigned to the active hero profile.
    private var profileQuests: [QuestCache] {
        // WHY: defensive — predicate is source of truth; in-memory guard for stale identity.
        guard let name = appState.currentProfile?.id.recordName else { return [] }
        return cachedQuests.filter { $0.assigneeRecordName == name && $0.isActive }
    }

    /// Completions logged by the active hero profile.
    private var profileLogs: [QuestCompletionCache] {
        // WHY: defensive — store is source of truth; guards identity drift.
        guard let name = appState.currentProfile?.id.recordName else { return [] }
        return cachedCompletions.filter { $0.completerRecordName == name }
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
            .task {
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
        }
        // WHY: view identity tracks profileRecordName so @Query predicates (init-captured) are recreated on profile switch; defensive filter in rebuild() is secondary guard.
        .id(profileRecordName)
    }

    // MARK: - Subviews

    private var scrollContent: some View {
        VStack(spacing: DesignSystemConstants.Padding.standard) {
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
                    GemShopView()
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
                    .fill(Color(.secondarySystemGroupedBackground))
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
                    .fill(Color(.tertiarySystemFill))

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
                .fill(Color.accentColor.opacity(0.12))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .foregroundStyle(Color.accentColor)
    }

    // MARK: - Helpers

    private var gemsBalance: Int? {
        guard let profile = appState.currentProfile else { return nil }
        let family = appState.family?.id.recordName ?? profile.family.recordID.recordName
        do {
            return try gemService.balance(for: profile.id.recordName, familyRecordName: family)
        } catch {
            Self.logger.warning("HeroHomeView.gemsBalance: failed to fetch gem balance: \(error, privacy: .private)")
            return nil
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
}
