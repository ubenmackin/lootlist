//
//  MyGoalsView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import os
import SwiftData
import SwiftUI

/// Child-centric savings screen displaying goal cards and ledger-derived progress.
struct MyGoalsView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?
    @Environment(GoalService.self) private var envGoalService: GoalService?
    @Environment(ToastManager.self) private var toastManager: ToastManager?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "MyGoals")

    @Query private var cachedGoals: [GoalCache]
    @Query private var cachedLedgers: [LedgerEntryCache]

    @State private var isShowingGoalEditor: Bool = false
    @State private var goalToEdit: GoalCache?
    @State private var goalToDelete: GoalCache?
    @State private var errorMessage: String?

    private let familyRecordName: String?
    private let profileRecordName: String?
    private let goalService: GoalService?

    private var resolvedGoalService: GoalService? {
        goalService ?? envGoalService
    }

    init(familyRecordName: String? = nil, profileRecordName: String? = nil, goalService: GoalService? = nil) {
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName
        self.goalService = goalService

        let targetFamily = familyRecordName ?? ""
        let targetProfile = profileRecordName ?? ""
        FamilyScopeValidator.validateOrFault(targetFamily: targetFamily, viewName: "MyGoalsView")
        // WHY: predicate pushdown — filter by family+profile at store; fail-closed to 0 rows when empty.
        let goalFilter = #Predicate<GoalCache> { $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile }
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile }

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
        // WHY: defensive secondary guard — predicate is source of truth; filters stale identity when view not yet recreated.
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

    /// Computes cumulative saved pennies for a goal from deterministic
    /// contribution records via the shared ``GoalProgressCalculator``.
    private func savedPennies(for goal: GoalCache) -> Int64 {
        GoalProgressCalculator.contributionPennies(for: goal, in: cachedLedgers)
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
            .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
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
            .sheet(item: $goalToEdit) { goal in
                GoalEditorSheet(
                    goal: goal,
                    onSave: { draft in
                        try await updateGoal(goal, draft: draft)
                    },
                    onDelete: {
                        try await deleteGoal(goal)
                    }
                )
            }
            .alert(
                "Delete Goal?",
                isPresented: Binding(
                    get: { goalToDelete != nil },
                    set: {
                        if !$0 {
                            goalToDelete = nil
                        }
                    }
                ),
                presenting: goalToDelete
            ) { goal in
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await deleteGoal(goal)
                        } catch {
                            Self.logger.error("Failed to delete goal \(goal.recordName, privacy: .private): \(error, privacy: .private)")
                            toastManager?.show(message: "Couldn’t delete “\(goal.name)”. Please try again.", type: .error)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    goalToDelete = nil
                }
            } message: { goal in
                Text("Are you sure you want to delete “\(goal.name)”?")
            }
            .refreshable {
                await lifecycleCoordinator?.performManualSync()
            }
            .onChange(of: errorMessage) { _, msg in
                // The toast overlay is available via the root view; errors
                // surface as a validation message stored in parsing-error state.
                if msg != nil {
                    Task {
                        do {
                            try await Task.sleep(for: .seconds(4))
                        } catch {
                            Self.logger.debug("Error message auto-dismiss interrupted: \(error, privacy: .private)")
                        }
                        errorMessage = nil
                    }
                }
            }
        }
        // WHY: view identity tracks profileRecordName so @Query predicates (init-captured) are recreated on profile switch; defensive filter in activeGoals is secondary guard.
        .id(profileRecordName)
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

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                ForEach(goals, id: \.recordName) { goal in
                    Button {
                        goalToEdit = goal
                    } label: {
                        goalCard(for: goal)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            goalToEdit = goal
                        } label: {
                            Label("Edit Goal", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            goalToDelete = goal
                        } label: {
                            Label("Delete Goal", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            goalToDelete = goal
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            goalToEdit = goal
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(Color(DesignSystemConstants.Colors.accentBlue))
                    }
                }
            }
        }
    }

    // MARK: - Goal Card

    @ViewBuilder
    private func goalCard(for goal: GoalCache) -> some View {
        let saved = Double(savedPennies(for: goal)) / 100.0
        let target = Double(goal.targetAmountPennies) / 100.0
        let isCompleted = goal.completedAt != nil
        let pacing = GoalPacingCalculator.calculatePacing(
            targetAmountPennies: goal.targetAmountPennies,
            savedPennies: savedPennies(for: goal),
            createdAt: goal.createdAt,
            targetDate: goal.targetDate,
            completedAt: goal.completedAt
        )
        let validURL = goal.linkURL.flatMap { LinkMetadataService.normalizeURL(from: $0) }
        let validImageURL: URL? = {
            guard let raw = goal.imageURL, !raw.isEmpty,
                  let url = URL(string: raw),
                  url.scheme?.lowercased().hasPrefix("http") == true else { return nil }
            return url
        }()
        let progress = target > 0 && target.isFinite && saved.isFinite ? min(max(saved / target, 0), 1) : 0.0
        let percent = Int((progress * 100).rounded())

        VStack(alignment: .leading, spacing: 10) {
            goalCardHeader(for: goal, pacing: pacing, isCompleted: isCompleted, validURL: validURL, validImageURL: validImageURL)
            goalCardStatusLine(saved: saved, target: target, pacing: pacing, isCompleted: isCompleted)
            goalCardProgressBar(progress: progress)
            goalCardFooter(for: goal, percent: percent, isCompleted: isCompleted, pacing: pacing)
        }
        .padding(DesignSystemConstants.Padding.medium)
        .hoverEffect(.highlight)
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

    private func goalCardHeader(for goal: GoalCache, pacing: GoalPacingCalculator.PacingSummary?, isCompleted: Bool, validURL: URL?, validImageURL: URL?) -> some View {
        HStack(spacing: 8) {
            goalCardIcon(for: goal, validImageURL: validImageURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(goal.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let pacing, pacing.status != .noDeadline {
                    HStack(spacing: 4) {
                        Image(systemName: pacing.status.iconSystemName)
                            .font(.caption2)
                        Text(pacing.status.badgeText)
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(pacing.status.tintColor)
                }
            }
            Spacer()
            if let validURL {
                Link(destination: validURL) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.subheadline)
                        .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View \(goal.name) online")
            }
            if isCompleted {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                    .accessibilityLabel("Completed")
            }
        }
    }

    @ViewBuilder
    private func goalCardIcon(for goal: GoalCache, validImageURL: URL?) -> some View {
        if let validImageURL {
            AsyncImage(url: validImageURL) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(width: 44, height: 44)
                        .background(Color(DesignSystemConstants.Colors.cardSurface))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                case .failure:
                    Text(goal.emojiIcon ?? "🎯")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .background(Color(DesignSystemConstants.Colors.cardSurface))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                @unknown default:
                    Color(DesignSystemConstants.Colors.cardSurface)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .frame(width: 44, height: 44)
        } else {
            Text(goal.emojiIcon ?? "🎯")
                .font(.title2)
        }
    }

    private func goalCardStatusLine(saved: Double, target: Double, pacing: GoalPacingCalculator.PacingSummary?, isCompleted: Bool) -> some View {
        HStack(spacing: 4) {
            Text(CurrencyFormatter.string(saved))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
            Text("of")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(CurrencyFormatter.string(target))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let pacing, !isCompleted {
                Spacer()
                Text(pacing.formattedTargetDate)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func goalCardProgressBar(progress: Double) -> some View {
        GeometryReader { geometry in
            let rawWidth = geometry.size.width
            let fillWidth: CGFloat = (rawWidth.isFinite && rawWidth > 0) ? rawWidth * CGFloat(progress) : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.15))
                    .frame(height: 8)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(DesignSystemConstants.Colors.primaryGreen))
                    .frame(width: fillWidth, height: 8)
            }
        }
        .frame(height: 8)
    }

    private func goalCardFooter(for goal: GoalCache, percent: Int, isCompleted: Bool, pacing: GoalPacingCalculator.PacingSummary?) -> some View {
        HStack {
            Text(isCompleted ? "✓ \(percent)% earned" : "\(percent)% earned")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
            Spacer()
            if let pacing, !isCompleted, pacing.daysRemaining > 7 {
                Text("Save \(CurrencyFormatter.string(pacing.weeklyRequiredSavingsDollars))/wk")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(pacing.status.tintColor)
            } else if let category = goal.category, !category.isEmpty {
                Text(category)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color(DesignSystemConstants.Colors.background))
                    )
            }
        }
    }

    private func accessibilityLabel(for goal: GoalCache, saved: Double, target: Double) -> String {
        let name = goal.name
        let percent = target > 0 ? Int((saved / target * 100).rounded()) : 0
        let completedText = goal.completedAt != nil ? ", completed" : ""
        return "\(name), \(percent) percent saved\(completedText)"
    }

    // MARK: - Save, Update & Delete Goal

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
            targetDate: draft.targetDate,
            linkURL: draft.linkURL,
            imageURL: draft.imageURL,
            for: profile,
            family: family
        )
        HapticsService.lightImpact()
    }

    private func updateGoal(_ goal: GoalCache, draft: GoalDraft) async throws {
        guard let service = resolvedGoalService else { return }
        try await service.updateGoal(goal, draft: draft, familyRecordName: familyRecordName)
        HapticsService.lightImpact()
    }

    private func deleteGoal(_ goal: GoalCache) async throws {
        guard let service = resolvedGoalService else { return }
        try await service.deleteGoal(goal, familyRecordName: familyRecordName)
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
