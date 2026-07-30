//
//  QuestLogView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import SwiftData
import SwiftUI

struct QuestLogView: View {
    @Environment(QuestService.self) private var questService
    @Environment(FamilyService.self) private var familyService
    @Environment(AppState.self) private var appState
    @Environment(AppSyncCoordinator.self) private var appSyncCoordinator

    @Query private var cachedProfiles: [ProfileCache]
    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]

    @State private var viewModel: QuestLogViewModel?

    let initialHero: ProfileCache?

    /// Family record name used to push the family filter down to SwiftData.
    /// When `nil` (no family loaded) the queries return zero rows, which is
    /// the correct behavior — there is no family to scope to.
    private let familyRecordName: String?

    init(initialHero: ProfileCache? = nil, familyRecordName: String? = nil) {
        self.initialHero = initialHero
        self.familyRecordName = familyRecordName

        // so we don't fetch every family's rows and post-filter in Swift.
        // Mirrors the L1 branch style in `CacheService.upsertX`: nil family
        // means "no filter", non-nil means "filter by family". We do NOT use
        // the banned `familyRecordName ?? ""` sentinel — that conflicts with
        let profileFilter: Predicate<ProfileCache>? = familyRecordName.map { name in
            #Predicate { $0.familyRecordName == name }
        }
        let questFilter: Predicate<QuestCache>? = familyRecordName.map { name in
            #Predicate { $0.familyRecordName == name }
        }
        let completionFilter: Predicate<QuestCompletionCache>? = familyRecordName.map { name in
            #Predicate { $0.familyRecordName == name }
        }
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
    }

    var body: some View {
        List {
            if viewModel?.isLoading == true, viewModel?.displayedQuests.isEmpty ?? true {
                ProgressView("Loading quest log…")
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            } else if let vm = viewModel, vm.displayedQuests.isEmpty {
                emptyState
            } else {
                questRows
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Quest Log")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                heroPickerMenu
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                dateRangeMenu
                completionFilterMenu
            }
        }
        .task {
            if viewModel == nil {
                let vm = QuestLogViewModel(
                    questService: questService,
                    familyService: familyService,
                    appState: appState
                )
                viewModel = vm
            }
            viewModel?.subscribeToSyncEvents(appSyncCoordinator)
            if let initialHero, viewModel?.selectedHero == nil {
                viewModel?.selectedHero = initialHero
            }
            // snapshot. Subsequent mutations re-fire `.onChange`.
            rebuildViewModel()
        }
        .onDisappear {
            viewModel?.unsubscribeFromSyncEvents(appSyncCoordinator)
        }
        .onChange(of: cachedProfiles) { _, _ in
            rebuildViewModel()
        }
        .onChange(of: cachedQuests) { _, _ in
            rebuildViewModel()
        }
        .onChange(of: cachedCompletions) { _, _ in
            rebuildViewModel()
        }
    }

    private func rebuildViewModel() {
        guard let vm = viewModel else { return }

        // The `@Query` declarations above already filter by
        // `familyRecordName` at the SwiftData/SQLite layer, so we no longer
        // post-filter the cached rows in Swift. Pass them straight through.
        vm.rebuildLists(profiles: cachedProfiles, quests: cachedQuests, logs: cachedCompletions)
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

    private var dateRangeMenu: some View {
        Menu {
            ForEach(QuestLogViewModel.DateRangePreset.allCases) { preset in
                Button {
                    viewModel?.dateRangePreset = preset
                } label: {
                    Label(preset.rawValue, systemImage: "checkmark")
                        .opacity(viewModel?.dateRangePreset == preset ? 1 : 0)
                }
            }
        } label: {
            Image(systemName: "calendar")
        }
    }

    private var completionFilterMenu: some View {
        Menu {
            ForEach(QuestLogViewModel.CompletionFilter.allCases) { filter in
                Button {
                    viewModel?.completionFilter = filter
                } label: {
                    Label(filter.rawValue, systemImage: "checkmark")
                        .opacity(viewModel?.completionFilter == filter ? 1 : 0)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }

    // MARK: - Quest Rows

    private var questRows: some View {
        ForEach(viewModel?.displayedQuests ?? []) { row in
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
                            .background(Capsule().fill(.red.opacity(0.15)))
                            .foregroundStyle(.red)
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
                    Text(
                        "💰 \(String(format: "%.0f", row.quest.goldReward)) / ⭐ \(row.quest.xpReward)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
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
                .foregroundStyle(.orange)
        case let .inProgress(completed, target):
            Text("⏳ In Progress (\(completed)/\(target))")
                .font(.caption)
                .foregroundStyle(.orange)
        case .completed:
            Text("✓ Completed")
                .font(.caption)
                .foregroundStyle(.green)
        case .rejected:
            Text("✗ Rejected")
                .font(.caption)
                .foregroundStyle(.red)
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
