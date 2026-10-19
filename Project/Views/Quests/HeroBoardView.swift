//
//  HeroBoardView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftData
import SwiftUI

@MainActor
struct HeroBoardView: View {
    private let appState: AppState
    private let questService: QuestService
    private let familyRecordName: String?

    /// Identifiable hand-off for presenting the quest editor on a board row.
    private struct QuestEditTarget: Identifiable {
        let questRecordName: String
        var id: String {
            questRecordName
        }
    }

    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedProfiles: [ProfileCache]
    @Query private var cachedCompletions: [QuestCompletionCache]

    @State private var viewModel: HeroBoardViewModel
    @State private var isSubmitting = false
    @State private var pendingRemovalRowID: String?
    @State private var editingQuest: QuestEditTarget?
    @State private var editSheetViewModel: QuestManagerViewModel?

    init(
        questService: QuestService,
        appState: AppState,
        familyRecordName: String? = nil
    ) {
        self.questService = questService
        self.appState = appState
        self.familyRecordName = familyRecordName
        self._viewModel = State(initialValue: HeroBoardViewModel(
            boardService: HeroBoardService(questService: questService),
            appState: appState
        ))

        let targetFamily = familyRecordName ?? ""
        let questFilter = QuestCache.familyPredicate(familyRecordName: targetFamily)
        let profileFilter = ProfileCache.familyPredicate(familyRecordName: targetFamily)
        let completionFilter = QuestCompletionCache.familyPredicate(familyRecordName: targetFamily)

        // WHY: secondary recordName keeps ForEach stable after CloudKit reorders.
        _cachedQuests = Query(
            filter: questFilter,
            sort: [SortDescriptor(\QuestCache.questName), SortDescriptor(\QuestCache.recordName)]
        )
        _cachedProfiles = Query(
            filter: profileFilter,
            sort: [SortDescriptor(\ProfileCache.displayName), SortDescriptor(\ProfileCache.recordName)]
        )
        _cachedCompletions = Query(
            filter: completionFilter,
            sort: [SortDescriptor(\QuestCompletionCache.completedDate, order: .reverse), SortDescriptor(\QuestCompletionCache.recordName)]
        )
    }

    var body: some View {
        boardContent(vm: viewModel)
            .background(Color(DesignSystemConstants.Colors.background))
            .navigationTitle("Hero Board")
            .navigationBarTitleDisplayMode(.large)
            .onAppear { rebuildViewModel() }
            .refreshable {
                rebuildViewModel()
            }
            .onChange(of: cachedQuests) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedProfiles) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedCompletions) { _, _ in
                rebuildViewModel()
            }
            .sheet(item: $editingQuest, onDismiss: {
                // WHY clear on dismiss: the editor VM owns the shared questService sweep
                // callback while presented; dropping it here hands ownership back instead
                // of leaving a defunct instance attached after the sheet closes.
                editSheetViewModel = nil
            }, content: { target in
                if let vm = editSheetViewModel {
                    QuestAssignmentView(
                        mode: .edit(questRecordName: target.questRecordName),
                        viewModel: vm,
                        familyRecordName: familyRecordName ?? appState.family?.id.recordName
                    )
                }
            })
    }

    private func rebuildViewModel() {
        viewModel.rebuildLists(quests: cachedQuests, profiles: cachedProfiles, completions: cachedCompletions)
    }

    private func boardContent(vm: HeroBoardViewModel) -> some View {
        List {
            // Claim-loss feedback: when a pending optimistic claim is resolved
            // server-wins for another hero, ViewModel surfaces a toast and
            // local errorMessage; this hidden banner exposes the state for
            // accessibility/UI tests via heroBoard.claimLostToast.
            if let message = vm.errorMessage, message == "Another hero claimed this quest" {
                Text(message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                    .accessibilityIdentifier("heroBoard.claimLostToast")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if vm.availableRows.isEmpty, vm.isParent ? vm.claimedRows.isEmpty : true {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                if !vm.availableRows.isEmpty {
                    Section(vm.isParent ? "On the Board" : "Up for Grabs") {
                        ForEach(vm.availableRows) { row in
                            if vm.isParent {
                                parentAvailableRow(row)
                            } else {
                                claimableRow(row, vm: vm)
                            }
                        }
                    }
                }

                if vm.isParent, !vm.claimedRows.isEmpty {
                    Section("Claimed") {
                        ForEach(vm.claimedRows) { row in
                            claimedRow(row, vm: vm)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // Dedicated accessibility node for claim-loss toast so XCUITest can
        // assert the server-wins feedback without parsing global toast overlay.
        .overlay(alignment: .top) {
            if vm.errorMessage == "Another hero claimed this quest" {
                Color.clear
                    .frame(height: 1)
                    .accessibilityIdentifier("heroBoard.claimLostToast")
                    .accessibilityHidden(false)
            }
        }
    }

    private func questDetail(_ row: HeroBoardViewModel.BoardRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.quest.questName)
                .font(.subheadline.bold())
            Text(CurrencyFormatter.string(row.quest.goldReward))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Child-facing row: tapping claims the quest optimistically.
    private func claimableRow(_ row: HeroBoardViewModel.BoardRow, vm: HeroBoardViewModel) -> some View {
        // WHY optimistic rows stay visible while the claim save confirms.
        let pending = row.isPending || vm.isClaiming(row)
        return HStack(spacing: 12) {
            Image(systemName: "hand.tap.fill")
                .foregroundStyle(.tint)
            questDetail(row)
            Spacer()
            if pending {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView()
                    Text("Pending")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                        .accessibilityIdentifier("board.pendingBadge-\(row.id)")
                }
            } else {
                Button("Claim") {
                    Task { await vm.claim(row) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting)
                .accessibilityIdentifier("board.claimButton-\(row.id)")
            }
        }
        .contentShape(Rectangle())
        // A bare identifier on a List row collapses it into one opaque
        // accessibility element, which hides the Claim button from XCUITest;
        // .contain keeps the row addressable while exposing its children.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.availableRow-\(row.id)")
        .disabled(pending)
    }

    /// Parent-facing row for unclaimed board quests: edit the quest or remove
    /// it from the board, via context menu or trailing swipe.
    private func parentAvailableRow(_ row: HeroBoardViewModel.BoardRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            questDetail(row)
            Spacer()
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("board.parentRow-\(row.id)")
        .contextMenu {
            Button {
                openEditSheet(for: row)
            } label: {
                Label("Edit Quest", systemImage: "pencil")
            }
            Button(role: .destructive) {
                pendingRemovalRowID = row.id
            } label: {
                Label("Remove from Board", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingRemovalRowID = row.id
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .accessibilityIdentifier("board.removeAction-\(row.id)")
            Button {
                openEditSheet(for: row)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .accessibilityIdentifier("board.editAction-\(row.id)")
        }
        .confirmationDialog(
            "Remove from Hero Board",
            isPresented: removalConfirmation(for: row),
            titleVisibility: .visible
        ) {
            Button("Remove from Board", role: .destructive) {
                removeFromBoard(row)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(row.quest.questName)” will be removed for the whole family. This cannot be undone.")
        }
    }

    private func removalConfirmation(for row: HeroBoardViewModel.BoardRow) -> Binding<Bool> {
        Binding(
            get: { pendingRemovalRowID == row.id },
            set: { presented in
                if !presented {
                    pendingRemovalRowID = nil
                }
            }
        )
    }

    private func removeFromBoard(_ row: HeroBoardViewModel.BoardRow) {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            await viewModel.removeFromBoard(row)
        }
    }

    private func openEditSheet(for row: HeroBoardViewModel.BoardRow) {
        // WHY deferred construction: the editor's VM registers the shared questService
        // sweep callback on init, so it is ensured once and reused across edits
        // (QuestManagerView pattern) — a per-edit instance would overwrite the shared
        // callback each time. Dismissal clears it via the sheet's onDismiss above.
        ViewLifecycle.ensure(&editSheetViewModel) {
            QuestManagerViewModel(questService: questService, appState: appState)
        }
        editingQuest = QuestEditTarget(questRecordName: row.id)
    }

    /// Parent-facing row for claimed quests with the release-back-to-board action.
    private func claimedRow(_ row: HeroBoardViewModel.BoardRow, vm: HeroBoardViewModel) -> some View {
        // WHY optimistic claims surface pending until server-wins settles.
        let pending = row.isPending || vm.isClaiming(row)
        return HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.quest.questName)
                    .font(.subheadline.bold())
                Text("\(CurrencyFormatter.string(row.quest.goldReward)) · claimed by \(row.claimantName ?? "a hero")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if pending {
                    Text("Pending")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                        .accessibilityIdentifier("board.pendingBadge-\(row.id)")
                }
            }
            Spacer()
            if pending {
                ProgressView()
            }
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("board.claimedRow-\(row.id)")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                guard !isSubmitting else { return }
                isSubmitting = true
                Task {
                    defer { isSubmitting = false }
                    await vm.revoke(row)
                }
            } label: {
                Label("Revoke", systemImage: "arrow.uturn.backward")
            }
            .disabled(isSubmitting || pending)
            .accessibilityIdentifier("board.revokeAction-\(row.id)")
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "sparkles",
            title: "The board is clear",
            description: "No quests are posted right now. Check back soon!",
            verticalPadding: 64
        )
    }
}
