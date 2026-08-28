//
//  KidsSavingsGoalsView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftData
import SwiftUI

enum GoalProgressCalculator {
    static func allocations(goals: [GoalCache], ledgerEntries: [LedgerEntryCache]) -> [String: Int64] {
        let hasContribIDs = ledgerEntries.contains { $0.recordName.hasPrefix("contrib-") }
        if hasContribIDs {
            return directContributionAllocations(goals: goals, ledgerEntries: ledgerEntries)
        }
        return fifoAllocations(goals: goals, ledgerEntries: ledgerEntries)
    }

    private static func directContributionAllocations(goals: [GoalCache], ledgerEntries: [LedgerEntryCache]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for goal in goals where !goal.isArchived {
            let prefix = "contrib-\(goal.recordName)-"
            let pennies = ledgerEntries
                .filter { $0.recordName.hasPrefix(prefix) && $0.profileRecordName == goal.profileRecordName }
                .reduce(into: Int64(0)) { acc, entry in
                    acc += Int64((entry.amount * 100).rounded())
                }
            result[goal.recordName] = max(pennies, 0)
        }
        for goal in goals where result[goal.recordName] == nil {
            result[goal.recordName] = 0
        }
        return result
    }

    private static func fifoAllocations(goals: [GoalCache], ledgerEntries: [LedgerEntryCache]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        let grouped = Dictionary(grouping: goals.filter { !$0.isArchived }) { "\($0.profileRecordName)|\($0.bucketKind)" }
        for (_, bucketGoals) in grouped {
            let sorted = bucketGoals.sorted { $0.createdAt < $1.createdAt }
            guard let first = sorted.first else { continue }
            let profile = first.profileRecordName
            let bucket = first.bucketKind
            let bucketEntries = ledgerEntries.filter { $0.profileRecordName == profile && $0.bucketKind == bucket }
            // WHY: Ledger amounts are dollars; goal targets are pennies — convert once so FIFO math never drifts on floating point.
            let totalPennies = bucketEntries.reduce(into: Int64(0)) { acc, entry in
                acc += Int64((entry.amount * 100).rounded())
            }
            var remaining = max(totalPennies, 0)
            for goal in sorted {
                if goal.completedAt != nil {
                    result[goal.recordName] = goal.targetAmountPennies
                    remaining = max(remaining - goal.targetAmountPennies, 0)
                    continue
                }
                let alloc = min(remaining, goal.targetAmountPennies)
                result[goal.recordName] = alloc
                remaining -= alloc
            }
            for goal in sorted where result[goal.recordName] == nil {
                result[goal.recordName] = 0
            }
        }
        for goal in goals where result[goal.recordName] == nil {
            result[goal.recordName] = 0
        }
        return result
    }
}

struct KidsSavingsGoalsView: View {
    private let familyRecordName: String?
    private let focusedProfileRecordName: String?

    @Environment(AppState.self) private var appState
    @Environment(GoalService.self) private var goalService: GoalService?
    @Environment(ToastManager.self) private var toastManager: ToastManager?

    @Query private var goalCaches: [GoalCache]
    @Query private var profileCaches: [ProfileCache]
    @Query private var ledgerCaches: [LedgerEntryCache]

    @State private var goalToEdit: GoalCache?
    @State private var goalToDelete: GoalCache?

    init(familyRecordName: String? = nil, focusedProfileRecordName: String? = nil) {
        self.familyRecordName = familyRecordName
        self.focusedProfileRecordName = focusedProfileRecordName
        let targetFamily = familyRecordName ?? ""
        let goalFilter = #Predicate<GoalCache> { $0.familyRecordName == targetFamily }
        let profileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
        _goalCaches = Query(filter: goalFilter, sort: \GoalCache.createdAt)
        _profileCaches = Query(filter: profileFilter, sort: \ProfileCache.displayName)
        _ledgerCaches = Query(filter: ledgerFilter, sort: \LedgerEntryCache.date, order: .reverse)
    }

    private var heroProfiles: [ProfileCache] {
        let heroes = profileCaches.filter { $0.roleEnum == .hero && $0.isActive }
        // WHY: HeroDetail deep-link must land with focused hero visible without scrolling.
        guard let focused = focusedProfileRecordName else { return heroes }
        return heroes.sorted { lhs, rhs in
            if lhs.recordName == focused {
                return true
            }
            if rhs.recordName == focused {
                return false
            }
            return lhs.displayName < rhs.displayName
        }
    }

    private var allocations: [String: Int64] {
        GoalProgressCalculator.allocations(goals: goalCaches, ledgerEntries: ledgerCaches)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if heroProfiles.isEmpty {
                    emptyState
                } else {
                    ForEach(heroProfiles, id: \.recordName) { hero in
                        heroSection(hero: hero)
                    }
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Savings Goals")
        .navigationBarTitleDisplayMode(.inline)
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
                        // already toasted in deleteGoal — intentional swallow
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                goalToDelete = nil
            }
        } message: { goal in
            Text("Are you sure you want to delete “\(goal.name)” for \(displayName(for: goal.profileRecordName))?")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "target")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No Savings Goals Yet")
                .font(.headline)
            Text("When heroes create savings goals they will appear here grouped by child.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func heroSection(hero: ProfileCache) -> some View {
        let goals = goalCaches.filter { $0.profileRecordName == hero.recordName && !$0.isArchived }
            .sorted { $0.createdAt < $1.createdAt }
        let accent = accentColor(for: hero)

        return VStack(alignment: .leading, spacing: 12) {
            heroHeader(hero: hero, accent: accent)

            if goals.isEmpty {
                Text("No active goals")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 12) {
                    ForEach(goals, id: \.recordName) { goal in
                        goalCard(goal: goal, hero: hero, accent: accent)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accent.opacity(0.25), lineWidth: 1.2)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kidsGoals.section-\(hero.recordName)")
    }

    private func heroHeader(hero: ProfileCache, accent: Color) -> some View {
        HStack(spacing: 10) {
            Text(hero.avatarEmoji ?? "🦸")
                .font(.title2)
                .frame(width: 36, height: 36)
                .background(Circle().fill(accent.opacity(0.14)))
                .overlay(Circle().strokeBorder(accent.opacity(0.30), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(hero.displayName)
                    .font(.subheadline.weight(.bold))
                Text("\(goalsCount(for: hero.recordName)) goals")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func goalCard(goal: GoalCache, hero: ProfileCache, accent: Color) -> some View {
        let savedPennies = allocations[goal.recordName] ?? 0
        let targetPennies = max(goal.targetAmountPennies, 1)
        let fraction = min(max(Double(savedPennies) / Double(targetPennies), 0), 1)
        let percent = Int((fraction * 100).rounded())
        let remainingPennies = max(targetPennies - savedPennies, 0)
        let remainingDollars = Double(remainingPennies) / 100.0
        let isCompleted = goal.completedAt != nil || savedPennies >= goal.targetAmountPennies

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(goal.emojiIcon ?? "🎯")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let category = goal.category, !category.isEmpty {
                        Text(category)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isCompleted {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.14)))
                }
                Menu {
                    Button {
                        goalToEdit = goal
                    } label: {
                        Label("Edit Goal", systemImage: "pencil")
                    }
                    .disabled(!canModifyGoals)

                    Button(role: .destructive) {
                        goalToDelete = goal
                    } label: {
                        Label("Delete Goal", systemImage: "trash")
                    }
                    .disabled(!canModifyGoals)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .accessibilityLabel("Goal actions for \(goal.name)")
            }

            ProgressBar(value: Double(savedPennies), maximum: Double(targetPennies), label: nil, tint: accent, height: 10)

            HStack(spacing: 6) {
                Text("\(percent)% Earned")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accent)
                    .monospacedDigit()
                    .accessibilityLabel("\(percent) percent earned")
                Text("·")
                    .foregroundStyle(.secondary)
                Text("\(CurrencyFormatter.string(remainingDollars)) Remaining")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Text(bucketLabel(for: goal.bucketKindEnum))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(.tertiarySystemFill)))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
        .contextMenu {
            Button {
                goalToEdit = goal
            } label: {
                Label("Edit Goal", systemImage: "pencil")
            }
            .disabled(!canModifyGoals)

            Button(role: .destructive) {
                goalToDelete = goal
            } label: {
                Label("Delete Goal", systemImage: "trash")
            }
            .disabled(!canModifyGoals)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(goal: goal, hero: hero, percent: percent, remainingDollars: remainingDollars))
        .accessibilityIdentifier("kidsGoals.goalCard-\(goal.recordName)")
    }

    private func bucketLabel(for kind: BucketKind?) -> String {
        switch kind {
        case .shortTermSave: "Short-Term Save"
        case .longTermSave: "Long-Term Save"
        case .spend: "Spend"
        case .none: "Save"
        }
    }

    private func goalsCount(for profileRecordName: String) -> Int {
        goalCaches.filter { $0.profileRecordName == profileRecordName && !$0.isArchived }.count
    }

    private func displayName(for profileRecordName: String) -> String {
        profileCaches.first { $0.recordName == profileRecordName }?.displayName ?? "Hero"
    }

    private func accessibilityLabel(goal: GoalCache, hero: ProfileCache, percent: Int, remainingDollars: Double) -> String {
        "\(hero.displayName)'s \(goal.name), \(percent) percent earned, \(CurrencyFormatter.string(remainingDollars)) remaining"
    }

    private func accentColor(for hero: ProfileCache) -> Color {
        // WHY: Deterministic per-child color keeps each hero's goals visually grouped without storing an extra field.
        let palette: [Color] = [
            Color(DesignSystemConstants.Colors.accentBlue),
            Color(DesignSystemConstants.Colors.primaryGreen),
            Color(DesignSystemConstants.Colors.pendingAmber),
            Color(DesignSystemConstants.Colors.dangerRed)
        ]
        let hash = hero.recordName.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }

    private var canModifyGoals: Bool {
        goalService != nil
    }

    private func updateGoal(_ goal: GoalCache, draft: GoalDraft) async throws {
        guard let goalService else {
            toastManager?.show(message: "Could not update goal.", type: .error)
            return
        }
        do {
            try await goalService.updateGoal(goal, draft: draft, familyRecordName: appState.family?.id.recordName)
            toastManager?.show(message: "Goal updated.", type: .success)
        } catch {
            toastManager?.show(message: "Could not update goal. Please try again.", type: .error)
            throw error
        }
    }

    private func deleteGoal(_ goal: GoalCache) async throws {
        guard let goalService else {
            toastManager?.show(message: "Could not delete goal.", type: .error)
            return
        }
        do {
            try await goalService.deleteGoal(goal, familyRecordName: appState.family?.id.recordName)
            toastManager?.show(message: "Goal deleted.", type: .success)
        } catch {
            toastManager?.show(message: "Could not delete goal. Please try again.", type: .error)
            throw error
        }
    }
}
