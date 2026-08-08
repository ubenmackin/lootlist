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
    @Environment(ToastManager.self) private var toastManager

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

        // Filter queries by family at the SwiftData store layer. When familyRecordName is nil,
        // scope to an empty string ("") so zero rows are returned rather than fetching unscoped across all families.
        let targetFamily = familyRecordName ?? ""
        let profileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily }
        let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily }
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
            if let initialHero, viewModel?.selectedHero == nil {
                viewModel?.selectedHero = initialHero
            }
            rebuildViewModel()
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

        // Rebuild view model lists directly from cached SwiftData rows.
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
                            "\(CurrencyFormatter.string(row.quest.goldReward)) / ⭐ \(row.quest.xpReward)"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if case .pending = row.completionStatus, appState.currentProfile?.role != .hero {
                        HStack(spacing: 12) {
                            Spacer()
                            Button {
                                Task {
                                    let questName = row.quest.recordName
                                    if let pendingLog = cachedCompletions
                                        .first(where: { $0.questRecordName == questName && $0.verificationStatus == VerificationStatus.pending.rawValue })
                                    {
                                        let zoneID = questService.cloudKitReference.resolvedZoneID
                                        let domainLog = pendingLog.toQuestCompletion(zoneID: zoneID)
                                        if let parent = appState.currentProfile {
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
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.red.opacity(0.12)))
                            }
                            .buttonStyle(.plain)

                            Button {
                                Task {
                                    let questName = row.quest.recordName
                                    if let pendingLog = cachedCompletions
                                        .first(where: { $0.questRecordName == questName && $0.verificationStatus == VerificationStatus.pending.rawValue })
                                    {
                                        let zoneID = questService.cloudKitReference.resolvedZoneID
                                        let domainLog = pendingLog.toQuestCompletion(zoneID: zoneID)
                                        if let parent = appState.currentProfile {
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
                                    .background(Capsule().fill(Color.green))
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
