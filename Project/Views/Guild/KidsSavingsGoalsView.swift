//
//  KidsSavingsGoalsView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import SwiftData
import SwiftUI

// WHY: FIFO allocation must stay in one helper so a future GoalService can reuse it without duplicating bucket math.
enum GoalProgressCalculator {
    /// Returns saved pennies per goalRecordName.
    static func allocations(goals: [GoalCache], ledgerEntries: [LedgerEntryCache]) -> [String: Int64] {
        // If any ledger row uses the deterministic contribution ID scheme, attribute directly.
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
        // Ensure archived or missing goals map to zero so callers never force-unwrap.
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
    @Environment(\.modelContext) private var modelContext
    @Environment(CKSyncEngineCoordinator.self) private var syncCoordinator: CKSyncEngineCoordinator?
    @Environment(GoalService.self) private var goalService: GoalService?
    @Environment(ToastManager.self) private var toastManager: ToastManager?

    @Query private var goalCaches: [GoalCache]
    @Query private var profileCaches: [ProfileCache]
    @Query private var ledgerCaches: [LedgerEntryCache]

    @State private var goalToArchive: GoalCache?
    @State private var showArchiveConfirm: Bool = false

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
        // Keep focused hero at top so the deep-link from HeroDetail lands without scrolling.
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
                headerTitle
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
        .navigationTitle("KIDS SAVINGS GOALS")
        .navigationBarTitleDisplayMode(.large)
        .alert("Archive Goal?", isPresented: $showArchiveConfirm, presenting: goalToArchive) { goal in
            Button("Archive", role: .destructive) { archive(goal) }
            Button("Cancel", role: .cancel) { goalToArchive = nil }
        } message: { goal in
            Text("Archive \"\(goal.name)\" for \(displayName(for: goal.profileRecordName))? It will be hidden from the active goals list but kept for history.")
        }
    }

    private var headerTitle: some View {
        VStack(spacing: 6) {
            Text("KIDS SAVINGS GOALS")
                .font(.title2.weight(.heavy))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Text("All children's savings targets in one place. Tap Edit to adjust interest and match settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
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
            savingsConfigSummary(for: hero)

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
            // WHY: Parents need a discoverable path to the per-child savings engine without leaving context.
            NavigationLink(destination: GuildSettingsView(familyRecordName: familyRecordName)) {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                        .font(.caption2.weight(.bold))
                    Text("Edit")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(accent.opacity(0.14)))
                .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit savings settings for \(hero.displayName)")
            .accessibilityIdentifier("kidsGoals.editLink-\(hero.recordName)")
        }
    }

    private func savingsConfigSummary(for hero: ProfileCache) -> some View {
        let interestText: String = {
            guard hero.interestEnabled, let bucket = hero.interestBucketEnum else { return "Interest off" }
            let pct = Double(hero.interestRateBps) / 100.0
            let rate = pct.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f%%", pct) : String(format: "%.1f%%", pct)
            let kind = bucket == .shortTermSave ? "Short-Term" : bucket == .longTermSave ? "Long-Term" : "Spend"
            let mode = hero.interestIsCompound ? "compound" : "simple"
            return "Interest \(rate) → \(kind) (\(mode))"
        }()
        let matchText: String = {
            guard hero.matchEnabled else { return "Match off" }
            let pct = Double(hero.matchRateBps) / 100.0
            let rate = pct.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f%%", pct) : String(format: "%.1f%%", pct)
            if let cap = hero.matchMonthlyCapPennies {
                let dollars = Double(cap) / 100.0
                return "Match \(rate) cap \(CurrencyFormatter.string(dollars))/mo"
            }
            return "Match \(rate) no cap"
        }()

        return HStack(spacing: 4) {
            Image(systemName: "percent")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(interestText) · \(matchText)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            NavigationLink(destination: GuildSettingsView(familyRecordName: familyRecordName)) {
                Image(systemName: "pencil")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit interest and match for \(hero.displayName)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
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
                    Text(attributedTitle(goal: goal, hero: hero))
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
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.green.opacity(0.14)))
                }
                Menu {
                    Button(role: .destructive) {
                        goalToArchive = goal
                        showArchiveConfirm = true
                    } label: {
                        Label("Archive Goal", systemImage: "archivebox")
                    }
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
            Button(role: .destructive) {
                goalToArchive = goal
                showArchiveConfirm = true
            } label: {
                Label("Archive Goal", systemImage: "archivebox")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(goal: goal, hero: hero, percent: percent, remainingDollars: remainingDollars))
        .accessibilityIdentifier("kidsGoals.goalCard-\(goal.recordName)")
    }

    private func attributedTitle(goal: GoalCache, hero: ProfileCache) -> String {
        // WHY: Parent view must make ownership obvious at a glance — emoji plus "Maya's Target" avoids confusion when multiple children share a goal name.
        let emoji = goal.emojiIcon ?? hero.avatarEmoji ?? "🎯"
        return "\(emoji) \(hero.displayName)'s \(goal.name)"
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
        let palette: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo]
        let hash = hero.recordName.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }

    private func archive(_ goal: GoalCache) {
        guard let family = appState.family else {
            toastManager?.show(message: "Could not archive goal. No active family.", type: .error)
            return
        }
        let zoneID = appState.familyZoneID ?? family.id.zoneID
        let domainGoal = goal.toGoal(zoneID: zoneID)
        Task {
            do {
                if let goalService {
                    try await goalService.archiveGoal(domainGoal, family: family)
                } else {
                    goal.isArchived = true
                    try modelContext.save()
                    syncCoordinator?.enqueueSave(recordID: domainGoal.id, isOwner: appState.isZoneOwner)
                }
            } catch {
                toastManager?.show(message: "Could not archive goal. Please try again.", type: .error)
            }
        }
    }
}
