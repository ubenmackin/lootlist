//
//  QuestLogView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftData
import SwiftUI

struct QuestLogView: View {
    @Environment(QuestService.self) private var questService
    @Environment(FamilyService.self) private var familyService
    @Environment(AppState.self) private var appState

    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?
    @Environment(ToastManager.self) private var toastManager

    @Query private var cachedProfiles: [ProfileCache]
    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedTemplates: [QuestTemplateCache]
    @Query private var currentProfileRows: [ProfileCache]

    @State private var viewModel: QuestLogViewModel?

    /// Persisted date-range scope so the quest log reopens on the filter the
    /// user last selected. Stored in `UserDefaults` via `@AppStorage` so the
    /// selection survives app relaunches.
    @AppStorage("questLog.calendarScope") private var scope: CalendarScope = .allTime

    let initialHero: ProfileCache?

    /// Family record name used to push the family filter down to SwiftData.
    /// When `nil` (no family loaded) the queries return zero rows, which is
    /// the correct behavior — there is no family to scope to.
    private let familyRecordName: String?
    private let profileRecordName: String?

    init(initialHero: ProfileCache? = nil, familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.initialHero = initialHero
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName

        // Filter queries by family at the SwiftData store layer. When familyRecordName is nil,
        // scope to an empty string ("") so zero rows are returned rather than fetching unscoped across all families.
        let targetFamily = familyRecordName ?? ""
        let profileFilter = ProfileCache.familyPredicate(familyRecordName: targetFamily)
        let questFilter = QuestCache.familyIncludingInactivePredicate(familyRecordName: targetFamily)
        let completionFilter = QuestCompletionCache.familyPredicate(familyRecordName: targetFamily)
        let templateFilter = QuestTemplateCache.familyPredicate(familyRecordName: targetFamily)
        _cachedProfiles = Query(
            filter: profileFilter,
            sort: HubQueryProvider.profileSort()
        )
        _cachedQuests = Query(
            filter: questFilter,
            sort: HubQueryProvider.questSort()
        )
        _cachedCompletions = Query(
            filter: completionFilter,
            sort: HubQueryProvider.completionSort()
        )
        _cachedTemplates = Query(filter: templateFilter, sort: HubQueryProvider.templateSort())
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
    private var viewerRole: UserRole? {
        currentProfileRow?.roleEnum
    }

    private var showsNavigationTitle: Bool {
        initialHero == nil
    }

    private var showsHeroPicker: Bool {
        initialHero == nil
    }

    var body: some View {
        content
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(navigationTitleDisplayMode)
            // WHY: view identity tracks family+profile so @Query predicates (init-captured) are recreated on scope switch.
            .id("\(familyRecordName ?? "")-\(profileRecordName ?? "")")
    }

    private var navigationTitleText: String {
        showsNavigationTitle ? "Quest Log" : "Quests & Chores"
    }

    private var navigationTitleDisplayMode: NavigationBarItem.TitleDisplayMode {
        showsNavigationTitle ? .large : .inline
    }

    private var targetFamilyForStale: String {
        familyRecordName ?? appState.family?.id.recordName ?? ""
    }

    /// WHY struct-only: footnote and banner render this snapshot so the engine handle never enters the View.
    private var syncHealth: SyncHealthSnapshot {
        lifecycleCoordinator?.syncHealthSnapshot ?? SyncHealthSnapshot()
    }

    private var content: some View {
        VStack(spacing: 0) {
            dateRangeFilter
                .padding(.horizontal)
                .padding(.vertical, 8)

            staleBanner

            syncFootnote
                .padding(.horizontal)
                .padding(.bottom, 4)

            questList
        }
        .background(Color(DesignSystemConstants.Colors.background))
        .toolbar { questLogToolbar }
        .modifier(lifecycleModifier)
    }

    @ViewBuilder
    private var staleBanner: some View {
        if !targetFamilyForStale.isEmpty {
            StaleDataBanner(
                family: targetFamilyForStale,
                type: .quest,
                count: cachedQuests.count,
                isSyncing: syncHealth.isSyncing
            )
            .padding(.horizontal)
            .padding(.bottom, 4)
        }
    }

    private var questList: some View {
        List {
            questListBody
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await lifecycleCoordinator?.performManualSync()
            rebuildViewModel()
        }
    }

    @ViewBuilder
    private var questListBody: some View {
        if viewModel == nil {
            questLogSkeleton
        } else if let vm = viewModel, vm.displayedQuests.isEmpty {
            emptyState
        } else {
            questRows
        }
    }

    @ToolbarContentBuilder
    private var questLogToolbar: some ToolbarContent {
        if viewerRole != .hero, showsHeroPicker {
            ToolbarItem(placement: .topBarLeading) {
                heroPickerMenu
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            completionFilterMenu
        }
    }

    private var lifecycleModifier: some ViewModifier {
        LifecycleModifier(
            cachedProfiles: cachedProfiles,
            cachedQuests: cachedQuests,
            cachedCompletions: cachedCompletions,
            cachedTemplates: cachedTemplates,
            currentProfileRows: currentProfileRows,
            scope: scope,
            onAppear: { ensureViewModel() },
            onCacheChanged: { rebuildViewModel() },
            onScopeChanged: { newScope in
                viewModel?.dateRangePreset = newScope
            }
        )
    }

    private func ensureViewModel() {
        let isNew = viewModel == nil
        let vm = ViewLifecycle.ensure(&viewModel, factory: {
            QuestLogViewModel(
                questService: questService,
                familyService: familyService,
                appState: appState
            )
        })
        if isNew {
            vm.dateRangePreset = scope
        }
        if let initialHero, vm.selectedHero == nil {
            vm.selectedHero = initialHero
        }
        rebuildViewModel()
    }

    private func rebuildViewModel() {
        guard let vm = viewModel else { return }

        // WHY: row-derived hero pin keeps log scope cache-bound with fail-closed empty scope.
        if viewerRole == .hero, let heroRecordName = currentProfileRow?.recordName {
            if let childHeroCache = cachedProfiles.first(where: { $0.recordName == heroRecordName }) {
                vm.selectedHero = childHeroCache
            }
        }

        vm.rebuildLists(profiles: cachedProfiles, quests: cachedQuests, logs: cachedCompletions, templates: cachedTemplates)
    }

    // MARK: - Toolbar Menus

    private var heroPickerMenu: some View {
        Menu {
            Button {
                viewModel?.selectedHero = nil
            } label: {
                Label("All Heroes", systemImage: "checkmark")
                    .opacity(viewModel?.selectedHero == nil ? 1 : 0)
            }
            Divider()
            ForEach(viewModel?.availableHeroes ?? []) { hero in
                Button {
                    viewModel?.selectedHero = hero
                } label: {
                    Label(hero.displayName, systemImage: "checkmark")
                        .opacity(viewModel?.selectedHero?.recordName == hero.recordName ? 1 : 0)
                }
            }
        } label: {
            Image(systemName: "person.2")
        }
    }

    private var completionFilterMenu: some View {
        CheckmarkMenu(
            systemImage: "line.3.horizontal.decrease.circle",
            options: QuestLogViewModel.CompletionFilter.allCases,
            selected: viewModel?.completionFilter,
            onSelect: { viewModel?.completionFilter = $0 },
            title: { $0.rawValue }
        )
    }

    // MARK: - Date Range Filter

    private var dateRangeFilter: some View {
        CalendarScopeFilterView(
            // WHY: row-first payout day keeps week math cache-derived with session fallback.
            scope: $scope,
            payoutDay: currentProfileRow?.payoutDayEnum ?? appState.family?.payoutDay ?? .sunday
        )
    }

    /// WHY prod-safe subset: inline footnote mirrors iCloudStatusView counts without DEBUG diagnostics.
    private var syncFootnote: some View {
        SyncFootnoteView(
            pendingCount: syncHealth.pendingUploadCount,
            isSyncing: syncHealth.isSyncing,
            lastSyncedAt: syncHealth.lastSyncedAt
        )
        .accessibilityIdentifier("questLog.syncFootnote")
    }

    /// WHY redacted rows: skeleton holds list shape so hydration populates without jump.
    private var questLogSkeleton: some View {
        ForEach(0 ..< 5, id: \.self) { _ in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(DesignSystemConstants.Colors.cardSurface))
                        .frame(width: 120, height: 14)
                    Spacer()
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(DesignSystemConstants.Colors.cardSurface))
                        .frame(width: 48, height: 12)
                }
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
                    .frame(height: 18)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
                    .frame(width: 160, height: 12)
            }
            .padding(.vertical, 6)
            .redacted(reason: .placeholder)
            .listRowSeparator(.hidden)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading quest log")
        .accessibilityIdentifier("questLog.skeleton")
    }

    // MARK: - Quest Rows

    @ViewBuilder
    private var questRows: some View {
        if let vm = viewModel {
            ForEach(vm.displayedQuests) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.heroName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(row.heroIsActive ? .primary : .secondary)
                        if !row.heroIsActive {
                            Text("Removed")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(DesignSystemConstants.Colors.dangerRed).opacity(0.15)))
                                .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
                        }
                        Spacer()
                        Text(row.quest.weekOf, format: .dateTime.month().day())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(row.quest.questName)
                        .font(.body)

                    HStack {
                        completionBadge(row.completionStatus)
                        Spacer()
                        // XP stays invisible while the immersive layer is
                        // off, so rows show only the real money reward.
                        Text(CurrencyFormatter.string(row.quest.goldReward))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if case .pending = row.completionStatus, viewerRole != .hero {
                        HStack(spacing: 12) {
                            Spacer()
                            Button {
                                Task {
                                    let questName = row.quest.recordName
                                    if let pendingLog = cachedCompletions
                                        .first(where: { $0.questRecordName == questName && $0.verificationStatus == VerificationStatus.pending.rawValue })
                                    {
                                        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: pendingLog)
                                        let domainLog = pendingLog.toQuestCompletion(zoneID: zoneID)
                                        // WHY: mutation actor derives from the cache row so verify never reads session domain state.
                                        if let row = currentProfileRow {
                                            let parent = row.toProfile(zoneID: zoneID)
                                            do {
                                                _ = try await questService.reject(questLog: domainLog, by: parent)
                                            } catch {
                                                toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Text("Reject")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color(DesignSystemConstants.Colors.dangerRed).opacity(0.12)))
                            }
                            .buttonStyle(.plain)

                            Button {
                                Task {
                                    let questName = row.quest.recordName
                                    if let pendingLog = cachedCompletions
                                        .first(where: { $0.questRecordName == questName && $0.verificationStatus == VerificationStatus.pending.rawValue })
                                    {
                                        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: pendingLog)
                                        let domainLog = pendingLog.toQuestCompletion(zoneID: zoneID)
                                        // WHY: mutation actor derives from the cache row so verify never reads session domain state.
                                        if let row = currentProfileRow {
                                            let parent = row.toProfile(zoneID: zoneID)
                                            do {
                                                _ = try await questService.verify(questLog: domainLog, by: parent)
                                            } catch {
                                                toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                                            }
                                        }
                                    }
                                }
                            }
                            label: {
                                Text("Approve")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color(DesignSystemConstants.Colors.primaryGreen)))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func completionBadge(_ status: QuestLogViewModel.CompletionStatus) -> some View {
        switch status {
        case .notStarted:
            Text("Not Started")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .pending:
            Text("⏳ Pending")
                .font(.caption)
                .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
        case let .inProgress(completed, target):
            Text("⏳ In Progress (\(completed)/\(target))")
                .font(.caption)
                .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
        case .completed:
            Text("✓ Completed")
                .font(.caption)
                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
        case .rejected:
            Text("✗ Rejected")
                .font(.caption)
                .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "scroll")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No quests in this range")
                .font(.headline)
            Text("Try adjusting the filters or date range.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
        .listRowSeparator(.hidden)
    }
}

// MARK: - View Modifiers (extracted to keep body shallow for Swift 6 type-checker)

private extension QuestLogView {
    /// WHY split quest log lifecycle into a typed modifier: deep modifier chains stall the Swift 6 type-checker.
    struct LifecycleModifier: ViewModifier {
        let cachedProfiles: [ProfileCache]
        let cachedQuests: [QuestCache]
        let cachedCompletions: [QuestCompletionCache]
        let cachedTemplates: [QuestTemplateCache]
        let currentProfileRows: [ProfileCache]
        let scope: CalendarScope
        let onAppear: () -> Void
        let onCacheChanged: () -> Void
        let onScopeChanged: (CalendarScope) -> Void

        func body(content: Content) -> some View {
            applyRemaining(to: applyCore(to: content))
        }

        private func applyCore(to content: Content) -> some View {
            content
                .task { onAppear() }
                .onChange(of: cachedProfiles) { _, _ in onCacheChanged() }
                .onChange(of: cachedQuests) { _, _ in onCacheChanged() }
                .onChange(of: cachedCompletions) { _, _ in onCacheChanged() }
        }

        private func applyRemaining(to view: some View) -> some View {
            view
                .onChange(of: cachedTemplates) { _, _ in onCacheChanged() }
                .onChange(of: currentProfileRows) { _, _ in onCacheChanged() }
                .onChange(of: scope) { _, newScope in onScopeChanged(newScope) }
        }
    }
}
