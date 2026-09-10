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

    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedProfiles: [ProfileCache]
    @Query private var cachedCompletions: [QuestCompletionCache]

    @State private var viewModel: HeroBoardViewModel
    @State private var isSubmitting = false

    init(
        questService: QuestService,
        appState: AppState,
        familyRecordName: String? = nil
    ) {
        self.questService = questService
        self.appState = appState
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

    /// Parent-facing row for unclaimed quests (read-only).
    private func parentAvailableRow(_ row: HeroBoardViewModel.BoardRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            questDetail(row)
            Spacer()
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("board.parentRow-\(row.id)")
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
