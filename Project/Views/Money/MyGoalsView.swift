//
//  MyGoalsView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import SwiftData
import SwiftUI

/// Child-centric wishlist and savings screen. Displays goal cards grouped by
/// bucket (SHORT SAVE / LONG SAVE) in FIFO creation order. Completed goals
/// show a checkmark state. The "+" button opens GoalEditorSheet to create a
/// new savings goal.
struct MyGoalsView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?
    @Environment(GoalService.self) private var envGoalService: GoalService?

    @Query private var cachedGoals: [GoalCache]
    @Query private var cachedLedgers: [LedgerEntryCache]

    @State private var isShowingGoalEditor: Bool = false
    @State private var errorMessage: String?

    private let familyRecordName: String?
    private let goalService: GoalService?

    private var resolvedGoalService: GoalService? {
        goalService ?? envGoalService
    }

    init(familyRecordName: String? = nil, goalService: GoalService? = nil) {
        self.familyRecordName = familyRecordName
        self.goalService = goalService

        let targetFamily = familyRecordName ?? ""
        let goalFilter = #Predicate<GoalCache> { $0.familyRecordName == targetFamily }
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }

        _cachedGoals = Query(
            filter: goalFilter,
            sort: \GoalCache.createdAt
        )
        _cachedLedgers = Query(
            filter: ledgerFilter,
            sort: \LedgerEntryCache.date,
            order: .reverse
        )
    }

    /// Goals belonging to the current hero profile, excluding archived goals.
    private var activeGoals: [GoalCache] {
        guard let name = appState.currentProfile?.id.recordName else { return [] }
        return cachedGoals.filter {
            $0.profileRecordName == name && !$0.isArchived
        }
    }

    /// Goals grouped by bucket, sorted by creation date (FIFO order).
    private var shortSaveGoals: [GoalCache] {
        activeGoals.filter { $0.bucketKindEnum == .shortTermSave }
    }

    private var longSaveGoals: [GoalCache] {
        activeGoals.filter { $0.bucketKindEnum == .longTermSave }
    }

    /// Computes cumulative saved pennies for a goal from ledger entries whose
    /// record name follows the deterministic contribution-ID pattern
    /// `contrib-{goalRecordName}-{sourceEventID}`.
    private func savedPennies(for goal: GoalCache) -> Int64 {
        let prefix = "contrib-\(goal.recordName)-"
        return cachedLedgers
            .filter { $0.recordName.hasPrefix(prefix) }
            .reduce(into: Int64(0)) { acc, entry in
                acc += Int64((entry.amount * 100).rounded())
            }
    }

    /// Whether any content exists (including across both buckets).
    private var isEmpty: Bool {
        shortSaveGoals.isEmpty && longSaveGoals.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystemConstants.Padding.standard) {
                    if isEmpty {
                        emptyState
                    } else {
                        if !shortSaveGoals.isEmpty {
                            bucketSection(
                                header: "Short Save",
                                symbol: "🐿️",
                                goals: shortSaveGoals
                            )
                        }

                        if !longSaveGoals.isEmpty {
                            bucketSection(
                                header: "Long Save",
                                symbol: "🏦",
                                goals: longSaveGoals
                            )
                        }
                    }
                }
                .padding(.horizontal, DesignSystemConstants.Padding.standard)
                .padding(.top, DesignSystemConstants.Padding.small)
                .padding(.bottom, DesignSystemConstants.Padding.large)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("MY WISHLIST & SAVINGS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if resolvedGoalService != nil {
                        Button {
                            errorMessage = nil
                            isShowingGoalEditor = true
                        } label: {
                            Label("Add Goal", systemImage: "plus")
                                .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel("Add Goal")
                        .accessibilityIdentifier("goals.addGoalButton")
                    }
                }
            }
            .sheet(isPresented: $isShowingGoalEditor) {
                GoalEditorSheet { draft in
                    try await saveGoal(draft)
                }
            }
            .refreshable {
                await lifecycleCoordinator?.performManualSync()
            }
            .onChange(of: errorMessage) { _, msg in
                // The toast overlay is available via the root view; errors
                // surface as a validation message stored in parsing-error state.
                if msg != nil {
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        errorMessage = nil
                    }
                }
            }
        }
    }

    // MARK: - Bucket Section

    private func bucketSection(
        header: String,
        symbol: String,
        goals: [GoalCache]
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            SectionHeader(header) {
                Text(symbol)
                    .font(.subheadline)
            }

            ForEach(goals, id: \.recordName) { goal in
                goalCard(for: goal)
            }
        }
    }

    // MARK: - Goal Card

    @ViewBuilder
    private func goalCard(for goal: GoalCache) -> some View {
        let saved = Double(savedPennies(for: goal)) / 100.0
        let target = Double(goal.targetAmountPennies) / 100.0
        let isCompleted = goal.completedAt != nil

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(goal.emojiIcon ?? "🎯")
                    .font(.title2)

                Text(goal.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                if isCompleted {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title3)
                        .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                        .accessibilityLabel("Completed")
                }
            }

            // Saved / Target status line.
            HStack(spacing: 4) {
                Text(saved, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        isCompleted
                            ? Color(DesignSystemConstants.Colors.primaryGreen)
                            : Color(DesignSystemConstants.Colors.primaryGreen)
                    )

                Text("of")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(target, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Progress bar.
            let progress = target > 0 ? min(max(saved / target, 0), 1) : 0.0
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.15))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(
                            isCompleted
                                ? Color(DesignSystemConstants.Colors.primaryGreen)
                                : Color(DesignSystemConstants.Colors.primaryGreen)
                        )
                        .frame(width: max(0, geometry.size.width * progress), height: 8)
                }
            }
            .frame(height: 8)

            // Footer: percent earned + category.
            let percent = Int((progress * 100).rounded())
            HStack {
                Text(isCompleted ? "✓ \(percent)% earned" : "\(percent)% earned")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))

                Spacer()

                if let category = goal.category, !category.isEmpty {
                    Text(category)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color(.tertiarySystemFill))
                        )
                }
            }
        }
        .padding(DesignSystemConstants.Padding.medium)
        .background(
            RoundedRectangle(
                cornerRadius: DesignSystemConstants.CornerRadius.small,
                style: .continuous
            )
            .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: goal, saved: saved, target: target))
        .accessibilityIdentifier("goals.card-\(goal.recordName)")
    }

    private func accessibilityLabel(for goal: GoalCache, saved: Double, target: Double) -> String {
        let name = goal.name
        let percent = target > 0 ? Int((saved / target * 100).rounded()) : 0
        let completedText = goal.completedAt != nil ? ", completed" : ""
        return "\(name), \(percent) percent saved\(completedText)"
    }

    // MARK: - Save Goal

    private func saveGoal(_ draft: GoalDraft) async throws {
        guard let service = resolvedGoalService,
              let profile = appState.currentProfile,
              let family = appState.family
        else { return }

        _ = try await service.createGoal(
            name: draft.name,
            category: draft.category,
            emojiIcon: draft.emojiIcon,
            targetAmountPennies: draft.targetAmountPennies,
            bucketKind: draft.bucketKind,
            for: profile,
            family: family
        )
        HapticsService.lightImpact()
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "star.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))

            Text("Your Wishlist Awaits")
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)

            Text(
                "Set a savings goal and watch your progress grow. Whether it's a new game or a bike, every quest brings you closer!"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DesignSystemConstants.Padding.large)

            if resolvedGoalService != nil {
                Button {
                    isShowingGoalEditor = true
                } label: {
                    Label("Add Your First Goal", systemImage: "plus.circle.fill")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(DesignSystemConstants.Colors.primaryGreen))
                .padding(.top, 8)
                .accessibilityIdentifier("goals.emptyAddButton")
            }

            Spacer()
        }
        .padding(.top, 64)
        .frame(maxWidth: .infinity)
    }
}
