//
//  HeroBoardView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftData
import SwiftUI

struct HeroBoardView: View {
    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService

    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedProfiles: [ProfileCache]

    @State private var viewModel: HeroBoardViewModel?
    @State private var isSubmitting = false

    /// Family record name used to push the family filter down to SwiftData.
    /// When `nil` (no family loaded) the queries return zero rows, which is
    /// the correct behavior — there is no family to scope to.
    private let familyRecordName: String?

    init(familyRecordName: String? = nil) {
        self.familyRecordName = familyRecordName

        let targetFamily = familyRecordName ?? ""
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let profileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }

        _cachedQuests = Query(
            filter: questFilter,
            sort: \QuestCache.questName
        )
        _cachedProfiles = Query(
            filter: profileFilter,
            sort: \ProfileCache.displayName
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    boardContent(vm: vm)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Hero Board")
            .navigationBarTitleDisplayMode(.large)
            .task { ensureViewModel() }
            .refreshable {
                rebuildViewModel()
            }
            .onChange(of: cachedQuests) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedProfiles) { _, _ in
                rebuildViewModel()
            }
            .toastOverlay()
        }
    }

    private func ensureViewModel() {
        ViewLifecycle.ensureAndRebuild(&viewModel, factory: {
            HeroBoardViewModel(
                boardService: HeroBoardService(questService: questService),
                appState: appState
            )
        }, rebuild: { _ in rebuildViewModel() })
    }

    private func rebuildViewModel() {
        guard let vm = viewModel else { return }
        vm.rebuildLists(quests: cachedQuests, profiles: cachedProfiles)
    }

    private func boardContent(vm: HeroBoardViewModel) -> some View {
        List {
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
    }

    private func questDetail(_ row: HeroBoardViewModel.BoardRow) -> some View {
        let rarity = row.quest.rarity
        return VStack(alignment: .leading, spacing: 2) {
            Text(row.quest.displayName)
                .font(.subheadline.bold())
            // Rarity renders as a plain effort label while the immersive
            // layer is off; the XP figure stays hidden.
            Text("\(CurrencyFormatter.string(row.quest.goldReward)) · \(FlavorTextProvider.rewardTierName(for: rarity))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Child-facing row: tapping claims the quest optimistically.
    private func claimableRow(_ row: HeroBoardViewModel.BoardRow, vm: HeroBoardViewModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.tap.fill")
                .foregroundStyle(.tint)
            questDetail(row)
            Spacer()
            if vm.isClaiming(row) {
                ProgressView()
            } else {
                Button("Claim") {
                    Task { await vm.claim(row) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || vm.isClaiming(row))
                .accessibilityIdentifier("board.claimButton-\(row.id)")
            }
        }
        .contentShape(Rectangle())
        // A bare identifier on a List row collapses it into one opaque
        // accessibility element, which hides the Claim button from XCUITest;
        // .contain keeps the row addressable while exposing its children.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.availableRow-\(row.id)")
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
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.quest.displayName)
                    .font(.subheadline.bold())
                Text("\(CurrencyFormatter.string(row.quest.goldReward)) · claimed by \(row.claimantName ?? "a hero")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
            .disabled(isSubmitting)
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
