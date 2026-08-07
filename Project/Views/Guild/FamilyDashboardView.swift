//
//  FamilyDashboardView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import SwiftData
import SwiftUI

struct FamilyDashboardView: View {
    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(FamilyService.self) private var familyService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService
    @Environment(AppSyncCoordinator.self) private var appSyncCoordinator
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewModel: FamilyDashboardViewModel?
    @State private var showShareSheet: Bool = false

    @Query private var cachedProfiles: [ProfileCache]
    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]
    @Query private var cachedAchievements: [AchievementCache]
    @Query private var cachedProfileAchievements: [ProfileAchievementCache]

    /// Family record name used to push the family filter down to SwiftData.
    /// When `nil` (no family loaded) the queries return zero rows, which is
    /// the correct behavior — there is no family to scope to.
    private let familyRecordName: String?

    init(familyRecordName: String? = nil) {
        self.familyRecordName = familyRecordName

        // Filter queries by family at the SwiftData store layer. When familyRecordName is nil,
        // scope to an empty string ("") so zero rows are returned rather than fetching unscoped across all families.
        let targetFamily = familyRecordName ?? ""
        let profileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily }
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
        let allowanceFilter = #Predicate<AllowancePeriodCache> { $0.familyRecordName == targetFamily }
        let achievementFilter = #Predicate<AchievementCache> { $0.familyRecordName == targetFamily }
        let profileAchievementFilter = #Predicate<ProfileAchievementCache> { $0.familyRecordName == targetFamily }
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
        _cachedLedgers = Query(
            filter: ledgerFilter,
            sort: \LedgerEntryCache.date,
            order: .reverse
        )
        _cachedAllowancePeriods = Query(
            filter: allowanceFilter,
            sort: \AllowancePeriodCache.weekOf,
            order: .reverse
        )
        _cachedAchievements = Query(
            filter: achievementFilter,
            sort: \AchievementCache.name
        )
        _cachedProfileAchievements = Query(
            filter: profileAchievementFilter,
            sort: \ProfileAchievementCache.earnedDate,
            order: .reverse
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let vm = viewModel {
                        loadedContent(vm: vm)
                    } else {
                        loadingPlaceholder
                    }
                }
                .padding(.vertical, 14)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(appState.family?.name ?? "Guild")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await viewModel?.refresh() }
            .task {
                if viewModel == nil {
                    viewModel = FamilyDashboardViewModel(
                        questService: questService,
                        treasury: treasury,
                        achievementService: achievementService,
                        familyService: familyService,
                        appState: appState
                    )
                }
                viewModel?.subscribeToSyncEvents(appSyncCoordinator)
                rebuild()
            }
            .task(id: scenePhase) {
                if scenePhase == .active {
                    await viewModel?.refresh()
                }
            }
            .onChange(of: cachedProfiles) { _, _ in rebuild() }
            .onChange(of: cachedQuests) { _, _ in rebuild() }
            .onChange(of: cachedCompletions) { _, _ in rebuild() }
            .onChange(of: cachedLedgers) { _, _ in rebuild() }
            .onChange(of: cachedAllowancePeriods) { _, _ in rebuild() }
            .onChange(of: cachedAchievements) { _, _ in rebuild() }
            .onChange(of: cachedProfileAchievements) { _, _ in rebuild() }
            .onDisappear {
                viewModel?.unsubscribeFromSyncEvents(appSyncCoordinator)
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: shareInviteItems)
            }
        }
    }

    private func rebuild() {
        // Rebuild view model lists directly from cached SwiftData rows.
        viewModel?.rebuildLists(
            profiles: cachedProfiles,
            quests: cachedQuests,
            logs: cachedCompletions,
            ledgers: cachedLedgers,
            allowancePeriods: cachedAllowancePeriods,
            profileAchievements: cachedProfileAchievements,
            achievements: cachedAchievements
        )
    }

    @State private var isProcessingPayout: Bool = false

    private var pendingCompletions: [QuestCompletionCache] {
        cachedCompletions.filter { $0.verificationStatus == VerificationStatus.pending.rawValue }
    }

    @ViewBuilder
    private func loadedContent(vm: FamilyDashboardViewModel) -> some View {
        parentHeaderCard
        if !pendingCompletions.isEmpty, appState.currentProfile?.role != .hero {
            pendingApprovalsCard
        }
        weeklySummaryCard(summary: vm.weekSummary)
        heroesSection(vm: vm)
        if let error = vm.loadError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal)
        }
    }

    private var parentHeaderCard: some View {
        HStack(spacing: 12) {
            if let profile = appState.currentProfile {
                let preset = AvatarPreset.preset(forProfile: profile)
                let spec = AvatarRenderSpec(
                    preset: preset,
                    customAvatarImageData: profile.customAvatarImageData,
                    displayName: profile.displayName,
                    levelTitle: profile.role.displayName,
                    equippedAccessory: nil,
                    avatarClass: profile.avatarClass,
                    role: profile.role
                )
                AvatarView(spec: spec, size: .small, showsNameAndTitle: false)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.body.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(profile.role.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Guild Master")
                    .font(.body.weight(.bold))
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.horizontal)
    }

    private var inviteButton: some View {
        Button {
            showShareSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.caption.weight(.bold))
                Text("Invite Heroes")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay(
                        Capsule().strokeBorder(Color.gold.opacity(0.45), lineWidth: 1)
                    )
            )
        }
        .accessibilityLabel("Invite Heroes. Tap to share invitation link.")
    }

    private var shareInviteItems: [Any] {
        appState.shareInviteItems
    }

    private var pendingApprovalsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Pending Approvals (\(pendingCompletions.count))", systemImage: "hourglass")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
            }

            VStack(spacing: 8) {
                ForEach(pendingCompletions, id: \.recordName) { completion in
                    let heroName = cachedProfiles.first { $0.recordName == completion.completerRecordName }?.displayName ?? "Hero"
                    let questName = cachedQuests.first { $0.recordName == completion.questRecordName }?.questName ?? "Quest"
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(questName)
                                .font(.subheadline.weight(.semibold))
                            Text("Submitted by \(heroName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        Button {
                            Task {
                                let zoneID = questService.cloudKitReference.resolvedZoneID
                                let domainLog = completion.toQuestCompletion(zoneID: zoneID)
                                if let parent = appState.currentProfile {
                                    _ = try? await questService.reject(questLog: domainLog, by: parent)
                                }
                            }
                        } label: {
                            Text("Reject")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.red.opacity(0.12)))
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task {
                                let zoneID = questService.cloudKitReference.resolvedZoneID
                                let domainLog = completion.toQuestCompletion(zoneID: zoneID)
                                if let parent = appState.currentProfile {
                                    _ = try? await questService.verify(questLog: domainLog, by: parent)
                                }
                            }
                        } label: {
                            Text("Approve")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.green))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemGroupedBackground)))
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.40), lineWidth: 1.5)
        )
        .padding(.horizontal)
    }

    private func weeklySummaryCard(summary: WeekendSummary?) -> some View {
        let lootDayTitle = appState.family?.payoutDay.lootDayTitle ?? "Sunday Loot Day"
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This Week's Haul")
                        .font(.headline)
                    Text(lootDayTitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let summary {
                    Text(summary.weekOf, format: .dateTime.month().day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary {
                totalsRow(summary: summary)

                if summary.totalEarned > 0, appState.currentProfile?.role != .hero {
                    ProcessPayoutButtonView(
                        summary: summary,
                        isProcessingPayout: isProcessingPayout,
                        onConfirmPayout: processPayout
                    )
                }

                Divider()

                whoCompletedWhatList(summary: summary)
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Tallying the guild's loot…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.gold.opacity(0.30), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    private func totalsRow(summary: WeekendSummary) -> some View {
        HStack(spacing: 16) {
            statBlock(
                icon: "banknote",
                value: CurrencyFormatter.string(summary.totalEarned),
                label: "Earned",
                tint: .gold
            )
            Divider()
            statBlock(
                icon: "checkmark.seal.fill",
                value: "\(summary.totalQuestsCompleted)",
                label: "Quests Completed",
                tint: .green
            )
            Divider()
            statBlock(
                icon: "person.2.fill",
                value: "\(summary.heroSummaries.count)",
                label: "Active Heroes",
                tint: .purple
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func statBlock(icon: String,
                           value: String,
                           label: String,
                           tint: Color) -> some View
    {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(value)
                    .font(.title3.weight(.bold).monospacedDigit())
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func whoCompletedWhatList(summary: WeekendSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Breakdown")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if summary.heroSummaries.isEmpty {
                Text("No quest activity recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(summary.heroSummaries) { hero in
                    HStack {
                        Text(hero.profile.displayName)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(hero.weeklyQuestsCompleted) quests")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(CurrencyFormatter.string(hero.weeklyGoldEarned))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.gold)
                    }
                }
            }
        }
    }

    private func heroesSection(vm: FamilyDashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Heroes")
                    .font(.headline)
                Spacer()
                inviteButton
            }
            .padding(.horizontal)

            if vm.heroes.isEmpty {
                emptyHeroesCard
            } else {
                VStack(spacing: 12) {
                    ForEach(vm.weekSummary?.heroSummaries ?? []) { summary in
                        NavigationLink {
                            QuestLogView(initialHero: summary.profile, familyRecordName: familyRecordName)
                                .environment(questService)
                                .environment(familyService)
                                .environment(appState)
                                .environment(appSyncCoordinator)
                        } label: {
                            HeroStatusCard(summary: summary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var emptyHeroesCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.orange)
            }

            VStack(spacing: 6) {
                Text("Recruit Your Party!")
                    .font(.title3.weight(.heavy))
                Text("Your guild needs heroes to embark on quests. Tap **Invite Heroes** above to share an invitation link or copy your guild code.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1.5)
        )
        .padding(.horizontal)
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "house")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
                .padding(.top, 120)
            Text("Summoning your guild…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func processPayout() async {
        isProcessingPayout = true
        defer { isProcessingPayout = false }
        guard appState.family != nil else { return }
        let zoneID = appState.family?.id.zoneID ?? familyService.cloudKitReference.resolvedZoneID
        let matchingPeriods = cachedAllowancePeriods.filter { period in
            let status = period.statusEnum
            return status == .active || status == .payoutPending
        }
        let activePeriods = matchingPeriods.map { $0.toAllowancePeriod(zoneID: zoneID) }
        for period in activePeriods {
            _ = try? await treasury.runPayout(period: period)
        }
    }
}

private struct ProcessPayoutButtonView: View {
    let summary: WeekendSummary
    let isProcessingPayout: Bool
    let onConfirmPayout: () async -> Void

    @State private var showEarlyPayoutConfirm: Bool = false

    var body: some View {
        Button {
            showEarlyPayoutConfirm = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "banknote.fill")
                Text("Process Payout Now 🎁")
                    .font(.subheadline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.gold.opacity(0.20)))
            .foregroundStyle(Color.gold)
        }
        .buttonStyle(.plain)
        .disabled(isProcessingPayout)
        .alert("Process Payout Now?", isPresented: $showEarlyPayoutConfirm) {
            Button("Confirm Payout", role: .destructive) {
                Task { await onConfirmPayout() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let amountStr = CurrencyFormatter.string(summary.totalEarned)
            let text = "Process payout of \(amountStr) across all heroes with completed quests? This will settle earnings for quests completed so far this week."
            Text(text)
        }
    }
}
