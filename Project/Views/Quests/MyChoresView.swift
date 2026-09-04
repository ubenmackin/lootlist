//
//  MyChoresView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import os
import SwiftData
import SwiftUI

/// Child-centric assigned chores screen displaying pending and open chores for the week.
struct MyChoresView: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "MyChoresView")
    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(ToastManager.self) private var toastManager: ToastManager?
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?

    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedTemplates: [QuestTemplateCache]

    @State private var submittingQuestIDs: Set<String> = []
    @State private var showCelebration: Bool = false
    @State private var pendingWithdrawal: PendingWithdrawal?
    @State private var isMissedExpanded: Bool = false

    struct PendingWithdrawal: Identifiable {
        let quest: QuestCache
        let log: QuestCompletionCache
        var id: String {
            quest.recordName
        }
    }

    /// Family and profile scope — when `nil` (no family/profile loaded) queries return zero rows fail-closed.
    private let familyRecordName: String?
    private let profileRecordName: String?

    init(familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName

        let targetFamily = familyRecordName ?? ""
        let targetProfile = profileRecordName ?? ""
        FamilyScopeValidator.validateOrFault(targetFamily: targetFamily, viewName: "MyChoresView")
        // WHY: predicate pushdown — filter by family+profile at store; avoids family-wide scan.
        let questFilter = #Predicate<QuestCache> {
            $0.familyRecordName == targetFamily && $0.assigneeRecordName == targetProfile
        }
        // WHY: hero-scoped completions — store filters by completer to avoid family-wide scan.
        let completionFilter = #Predicate<QuestCompletionCache> {
            $0.familyRecordName == targetFamily && $0.completerRecordName == targetProfile
        }
        // WHY: templates are family-scoped (shared across heroes).
        let templateFilter = #Predicate<QuestTemplateCache> {
            $0.familyRecordName == targetFamily
        }

        // WHY: stable sort — secondary recordName keeps ForEach stable after CloudKit reorders.
        _cachedQuests = Query(
            filter: questFilter,
            sort: [SortDescriptor(\QuestCache.weekOf, order: .reverse), SortDescriptor(\QuestCache.recordName)]
        )
        _cachedCompletions = Query(
            filter: completionFilter,
            sort: [SortDescriptor(\QuestCompletionCache.completedDate, order: .reverse), SortDescriptor(\QuestCompletionCache.recordName)]
        )
        _cachedTemplates = Query(
            filter: templateFilter,
            sort: \QuestTemplateCache.recordName
        )
    }

    private var payoutDay: PayoutDay {
        appState.resolvedPayoutDay
    }

    private var weekStart: Date {
        WeekMath.range(for: Date(), payoutDay: payoutDay).start
    }

    private var weekRange: Range<Date> {
        WeekMath.range(for: Date(), payoutDay: payoutDay).range
    }

    private var previousWeekStart: Date {
        WeekMath.weekStart(byAddingWeeks: -1, to: weekStart)
    }

    private var previousRange: Range<Date> {
        WeekMath.weekRange(starting: previousWeekStart)
    }

    private var myQuests: [QuestCache] {
        profileQuests
    }

    private func isFullyCompleted(for quest: QuestCache) -> Bool {
        let approved = profileLogs.filter { $0.questRecordName == quest.recordName && $0.isApproved }.count
        let target = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
        return GoldCalculation.isFullyCompleted(quest: quest, approvedCount: approved, effectiveTarget: target)
    }

    /// One-week carry-over includes inactive quests for visibility into missed items.
    private var missedLastWeek: [QuestCache] {
        guard let name = appState.currentProfile?.id.recordName else { return [] }
        return cachedQuests
            .filter { $0.assigneeRecordName == name }
            .filter { WeekMath.isQuestInCurrentWeek($0.weekOf, range: previousRange) }
            .filter { !isFullyCompleted(for: $0) }
            .filter { $0.targetCount > 1 || templatesByID[$0.templateRecordName]?.scheduleTypeEnum == .specificDays }
            .sorted(by: { $0.weekOf < $1.weekOf })
    }

    private var weekDays: [DayInfo] {
        HeroDashboardViewModel.currentWeekDays(payoutDay: payoutDay)
    }

    private var templatesByID: [String: QuestTemplateCache] {
        Dictionary(uniqueKeysWithValues: cachedTemplates.map { ($0.recordName, $0) })
    }

    /// Active quests assigned to the current hero profile.
    private var profileQuests: [QuestCache] {
        // WHY: defensive — predicate is source of truth; in-memory guard for stale identity.
        guard let name = appState.currentProfile?.id.recordName else { return [] }
        return cachedQuests.filter { $0.assigneeRecordName == name && $0.isActive }
    }

    /// Completions logged by the current hero, grouped by quest.
    private var profileLogs: [QuestCompletionCache] {
        // WHY: defensive — store is source of truth; guards identity drift.
        guard let name = appState.currentProfile?.id.recordName else { return [] }
        return cachedCompletions.filter { $0.completerRecordName == name }
    }

    private var weekQuests: [QuestCache] {
        profileQuests.filter { $0.isActive && WeekMath.isQuestInCurrentWeek($0.weekOf, range: weekRange) }
    }

    /// Quests that have been approved or completed by the hero — current week only.
    private var completedQuests: [(quest: QuestCache, log: QuestCompletionCache)] {
        var result: [(QuestCache, QuestCompletionCache)] = []
        for quest in weekQuests {
            let questLogs = profileLogs.filter { $0.questRecordName == quest.recordName }
            let approvedLogs = questLogs.filter(\.isApproved)
            let target = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
            if GoldCalculation.isFullyCompleted(quest: quest, approvedCount: approvedLogs.count, effectiveTarget: target),
               let latest = approvedLogs.sorted(by: { $0.completedDate > $1.completedDate }).first
            {
                result.append((quest, latest))
            }
        }
        return result.sorted(by: { $0.1.completedDate > $1.1.completedDate })
    }

    /// Quests whose latest completion is pending parent verification — current week only.
    private var pendingReviewQuests: [(quest: QuestCache, log: QuestCompletionCache)] {
        let completedQuestNames = Set(completedQuests.map(\.quest.recordName))
        var result: [(QuestCache, QuestCompletionCache)] = []
        guard let name = appState.currentProfile?.id.recordName else { return [] }
        let pendingBaseQuests = cachedQuests.filter {
            $0.assigneeRecordName == name && WeekMath.isQuestInCurrentWeek($0.weekOf, range: weekRange)
        }
        for quest in pendingBaseQuests where !completedQuestNames.contains(quest.recordName) {
            if let latestLog = profileLogs
                .filter({ $0.questRecordName == quest.recordName && $0.verificationStatusEnum == .pending })
                .sorted(by: { $0.completedDate > $1.completedDate })
                .first
            {
                result.append((quest, latestLog))
            }
        }
        return result.sorted(by: { $0.1.completedDate > $1.1.completedDate })
    }

    /// Overdue specific-days quests within the current week whose every scheduled day is past.
    private var overdueThisWeek: [QuestCache] {
        let pendingNames = Set(pendingReviewQuests.map(\.quest.recordName))
        var result: [QuestCache] = []
        for quest in weekQuests where quest.isActive {
            if pendingNames.contains(quest.recordName) {
                continue
            }
            let approvedCount = profileLogs.filter { $0.questRecordName == quest.recordName && $0.isApproved }.count
            let target = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
            if GoldCalculation.isFullyCompleted(quest: quest, approvedCount: approvedCount, effectiveTarget: target) {
                continue
            }
            guard quest.scheduleTypeEnum == .specificDays else { continue }
            let specDays = SpecificDaysHelper.specificDays(for: quest, templatesByID: templatesByID)
            guard !specDays.isEmpty else { continue }
            let allPast = specDays.allSatisfy { code in
                guard let day = weekDays.first(where: { $0.weekdayCode == code }) else { return false }
                return day.isPast
            }
            if allPast {
                result.append(quest)
            }
        }
        return result.sorted(by: { $0.weekOf < $1.weekOf })
    }

    /// Quests that are active and not completed/pending/overdue — current week only.
    private var upcomingQuests: [QuestCache] {
        let pendingNames = Set(pendingReviewQuests.map(\.quest.recordName))
        let completedNames = Set(completedQuests.map(\.quest.recordName))
        let overdueNames = Set(overdueThisWeek.map(\.recordName))
        let filtered = weekQuests.filter { quest in
            quest.isActive &&
                !pendingNames.contains(quest.recordName) &&
                !completedNames.contains(quest.recordName) &&
                !overdueNames.contains(quest.recordName)
        }
        let todayCode = WeekMath.weekdayCode(for: Date())
        return filtered.sorted(by: { lhs, rhs in
            let lhsToday = SpecificDaysHelper.isScheduledToday(quest: lhs, templatesByID: templatesByID, todayCode: todayCode)
            let rhsToday = SpecificDaysHelper.isScheduledToday(quest: rhs, templatesByID: templatesByID, todayCode: todayCode)
            if lhsToday != rhsToday {
                return lhsToday
            }
            return lhs.weekOf < rhs.weekOf
        })
    }

    /// Whether any current-week content exists — used for empty-state rendering.
    private var isEmpty: Bool {
        pendingReviewQuests.isEmpty && upcomingQuests.isEmpty && completedQuests.isEmpty && overdueThisWeek.isEmpty && missedLastWeek.isEmpty
    }

    private func approvedCount(for quest: QuestCache) -> Int {
        profileLogs.filter { $0.questRecordName == quest.recordName && $0.isApproved }.count
    }

    private func progressSuffix(for quest: QuestCache) -> String? {
        // WHY: day checklist splits reward per day, so denominator tracks day count for prorated credit.
        let effectiveTarget = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
        guard effectiveTarget > 1 else { return nil }
        let count = approvedCount(for: quest)
        return "\(count)/\(effectiveTarget)"
    }

    private func upcomingSubtitle(for quest: QuestCache) -> String? {
        let base = quest.descriptionText
        // WHY: day state always shows so Due Today versus Due Wed is visible at a glance.
        if SpecificDaysHelper.isDayChecklist(quest: quest, templatesByID: templatesByID) {
            let state = SpecificDaysHelper.dueText(
                for: quest,
                templatesByID: templatesByID,
                todayCode: WeekMath.weekdayCode(for: Date())
            )
            if let progress = progressSuffix(for: quest) {
                if let base, !base.isEmpty {
                    return "\(base) · \(state) · \(progress)"
                }
                return "\(state) · \(progress)"
            }
            if let base, !base.isEmpty {
                return "\(base) · \(state)"
            }
            return state
        }
        if let progress = progressSuffix(for: quest) {
            if let base, !base.isEmpty {
                return "\(base) · \(progress)"
            }
            return progress
        }
        return base
    }

    private func pendingSubtitle(for quest: QuestCache) -> String {
        // WHY: day state always shows so queued day stays visible while awaiting review.
        if SpecificDaysHelper.isDayChecklist(quest: quest, templatesByID: templatesByID) {
            let state = SpecificDaysHelper.dueText(
                for: quest,
                templatesByID: templatesByID,
                todayCode: WeekMath.weekdayCode(for: Date())
            )
            return "\(state) · Tap to Unsubmit"
        }
        return "Tap to Unsubmit"
    }

    private func overdueSubtitle(for quest: QuestCache) -> String {
        if let progress = progressSuffix(for: quest) {
            return "Overdue · \(progress) · Tap to Complete"
        }
        return "Overdue · Tap to Complete"
    }

    private func missedSubtitle(for quest: QuestCache) -> String {
        if let progress = progressSuffix(for: quest) {
            return "Expired · \(progress)"
        }
        return "Expired"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystemConstants.Padding.standard) {
                    if isEmpty {
                        emptyState
                    } else {
                        if !pendingReviewQuests.isEmpty {
                            pendingSection
                        }

                        if !overdueThisWeek.isEmpty {
                            overdueSection
                        }

                        if !upcomingQuests.isEmpty {
                            upcomingSection
                        }

                        if !completedQuests.isEmpty {
                            completedSection
                        }

                        if !missedLastWeek.isEmpty {
                            missedSection
                        }
                    }
                }
                .padding(.horizontal, DesignSystemConstants.Padding.standard)
                .padding(.top, DesignSystemConstants.Padding.small)
                .padding(.bottom, DesignSystemConstants.Padding.large)
            }
            .overlay {
                // Confetti celebration for auto-approved completions.
                CelebrationOverlay(isPresented: showCelebration)
            }
            .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
            .navigationTitle("My Quests")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Design-token spacing between toolbar items; Hero Board is a
                    // child-facing surface (not RPG-immersive), so no
                    // FeatureFlags.rpgImmersive gating — MyChoresView is hero-centric
                    // and both links are intentional for the child role.
                    HStack(spacing: DesignSystemConstants.Padding.small) {
                        NavigationLink {
                            QuestLogView(familyRecordName: familyRecordName)
                        } label: {
                            Label("Quest Log", systemImage: "scroll")
                        }
                        .accessibilityIdentifier("chores.questLogLink")

                        NavigationLink(value: "heroBoard") {
                            Label("Hero Board", systemImage: "square.grid.2x2.fill")
                        }
                        .accessibilityIdentifier("chores.heroBoardLink")
                    }
                }
            }
            .navigationDestination(for: String.self) { destination in
                if destination == "heroBoard" {
                    HeroBoardView(familyRecordName: familyRecordName)
                }
            }
            .refreshable {
                await lifecycleCoordinator?.performManualSync()
            }
            .alert(
                "Undo Completion?",
                isPresented: Binding(
                    get: { pendingWithdrawal != nil },
                    set: {
                        if !$0 {
                            pendingWithdrawal = nil
                        }
                    }
                ),
                presenting: pendingWithdrawal
            ) { target in
                Button("Undo Completion", role: .destructive) {
                    withdrawQuest(target.quest, log: target.log)
                }
                Button("Cancel", role: .cancel) {
                    pendingWithdrawal = nil
                }
            } message: { target in
                Text("Revert this completion for “\(target.quest.questName)” and move it back to to-do?")
            }
        }
        // WHY: view identity tracks profileRecordName so @Query predicates (init-captured) are recreated on profile switch.
        .id(profileRecordName)
    }

    // MARK: - Pending Review Section

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            SectionHeader("Sent for Review")

            ForEach(pendingReviewQuests, id: \.quest.recordName) { pair in
                Button {
                    pendingWithdrawal = PendingWithdrawal(quest: pair.quest, log: pair.log)
                } label: {
                    ChoreRowCard(
                        title: pair.quest.questName,
                        subtitle: pendingSubtitle(for: pair.quest),
                        amountText: "+\(CurrencyFormatter.string(pair.quest.goldReward))",
                        style: .pendingReview,
                        isSubmitting: submittingQuestIDs.contains(pair.quest.recordName),
                        onLeadingAction: {
                            pendingWithdrawal = PendingWithdrawal(quest: pair.quest, log: pair.log)
                        },
                        accessibilityID: "chores.pendingRow-\(pair.quest.recordName)"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Awaiting parent verification. Tap to unsubmit.")
            }
        }
    }

    // MARK: - Overdue Section

    private var overdueSection: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            SectionHeader("Overdue This Week")

            ForEach(overdueThisWeek) { quest in
                let questLogs = profileLogs.filter { $0.questRecordName == quest.recordName }
                // WHY: specific-days renders as day checklist so each approval ticks one weekday.
                if SpecificDaysHelper.isMultiPart(quest: quest, templatesByID: templatesByID) {
                    MultiPartQuestCard(
                        quest: quest,
                        logs: questLogs,
                        specificDays: SpecificDaysHelper.specificDays(for: quest, templatesByID: templatesByID),
                        subtitle: overdueSubtitle(for: quest),
                        amountText: "+\(CurrencyFormatter.string(quest.goldReward))",
                        isSubmitting: submittingQuestIDs.contains(quest.recordName),
                        onCompleteSubPart: { _ in
                            completeQuest(quest)
                        },
                        onWithdraw: { log in
                            pendingWithdrawal = PendingWithdrawal(quest: quest, log: log)
                        },
                        accessibilityID: "chores.overdueMultiRow-\(quest.recordName)"
                    )
                } else {
                    Button {
                        completeQuest(quest)
                    } label: {
                        ChoreRowCard(
                            title: quest.questName,
                            subtitle: overdueSubtitle(for: quest),
                            amountText: CurrencyFormatter.string(quest.goldReward),
                            style: .pendingReview,
                            isSubmitting: submittingQuestIDs.contains(quest.recordName),
                            onLeadingAction: {
                                completeQuest(quest)
                            },
                            accessibilityID: "chores.overdueRow-\(quest.recordName)"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Overdue quest. Tap to complete.")
                }
            }
        }
    }

    // MARK: - Upcoming Section

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            SectionHeader("Upcoming") {
                EmptyView()
            }

            ForEach(upcomingQuests) { quest in
                let questLogs = profileLogs.filter { $0.questRecordName == quest.recordName }
                // WHY: specific-days renders as day checklist so each approval ticks one weekday.
                if SpecificDaysHelper.isMultiPart(quest: quest, templatesByID: templatesByID) {
                    MultiPartQuestCard(
                        quest: quest,
                        logs: questLogs,
                        specificDays: SpecificDaysHelper.specificDays(for: quest, templatesByID: templatesByID),
                        subtitle: upcomingSubtitle(for: quest),
                        amountText: "+\(CurrencyFormatter.string(quest.goldReward))",
                        isSubmitting: submittingQuestIDs.contains(quest.recordName),
                        onCompleteSubPart: { _ in
                            completeQuest(quest)
                        },
                        onWithdraw: { log in
                            pendingWithdrawal = PendingWithdrawal(quest: quest, log: log)
                        },
                        accessibilityID: "chores.upcomingMultiRow-\(quest.recordName)"
                    )
                } else {
                    ChoreRowCard(
                        title: quest.questName,
                        subtitle: upcomingSubtitle(for: quest),
                        amountText: CurrencyFormatter.string(quest.goldReward),
                        style: .upcoming,
                        isSubmitting: submittingQuestIDs.contains(quest.recordName),
                        onLeadingAction: {
                            completeQuest(quest)
                        },
                        accessibilityID: "chores.upcomingRow-\(quest.recordName)"
                    )
                }
            }
        }
    }

    // MARK: - Completed Section

    private var completedSection: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            SectionHeader("Completed") {
                EmptyView()
            }

            ForEach(completedQuests, id: \.quest.recordName) { pair in
                ChoreRowCard(
                    title: pair.quest.questName,
                    subtitle: "Completed",
                    amountText: "+\(CurrencyFormatter.string(pair.quest.goldReward))",
                    style: .completed,
                    accessibilityID: "chores.completedRow-\(pair.quest.recordName)"
                )
                .accessibilityHint("Completed quest")
            }
        }
    }

    // MARK: - Missed Last Week Section

    private var missedSection: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            DisclosureGroup(isExpanded: $isMissedExpanded) {
                VStack(spacing: DesignSystemConstants.Padding.small) {
                    ForEach(missedLastWeek) { quest in
                        ChoreRowCard(
                            title: quest.questName,
                            subtitle: missedSubtitle(for: quest),
                            amountText: "Expired",
                            style: .expired,
                            accessibilityID: "chores.missedRow-\(quest.recordName)"
                        )
                    }
                }
                .padding(.top, DesignSystemConstants.Padding.small)
            } label: {
                HStack(spacing: 6) {
                    Text("Missed Last Week (\(missedLastWeek.count))")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .tint(.secondary)
        }
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("chores.missedDisclosure")
    }

    // MARK: - Actions

    private func withdrawQuest(_ quest: QuestCache, log: QuestCompletionCache) {
        let qID = quest.recordName
        guard !submittingQuestIDs.contains(qID) else { return }
        submittingQuestIDs.insert(qID)

        Task {
            defer { submittingQuestIDs.remove(qID) }
            guard let profile = appState.currentProfile else { return }
            do {
                try await questService.withdrawCompletion(questLog: log, by: profile)
                HapticsService.lightImpact()
            } catch {
                Self.logger.error("Failed to unsubmit quest: \(error, privacy: .private)")
            }
        }
    }

    private func completeQuest(_ quest: QuestCache) {
        let qID = quest.recordName
        guard !submittingQuestIDs.contains(qID) else { return }
        submittingQuestIDs.insert(qID)

        Task {
            defer { submittingQuestIDs.remove(qID) }
            guard let profile = appState.currentProfile
            else { return }

            let zoneID = appState.resolvedFamilyZoneID()
            let domain = quest.toQuest(zoneID: zoneID)

            let priorApproved = profileLogs.filter { $0.questRecordName == qID && $0.isApproved }.count

            do {
                let completion = try await questService.markComplete(
                    quest: domain,
                    by: profile
                )
                QuestCompletionHelper.handleCompletionResult(
                    completion,
                    quest: quest,
                    priorApproved: priorApproved,
                    toastManager: toastManager,
                    showCelebration: $showCelebration
                )
            } catch {
                Self.logger.error("Failed to mark chore complete: \(error, privacy: .private)")
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))

            Text("All Caught Up! 🎉")
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)

            Text(
                "You don't have any chores right now. When a parent assigns you a new quest, it'll show up here."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DesignSystemConstants.Padding.large)

            Spacer()
        }
        .padding(.top, 64)
        .frame(maxWidth: .infinity)
    }
}
