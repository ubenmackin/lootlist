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
    @Environment(ToastManager.self) private var toastManager
    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(FamilyService.self) private var familyService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService
    @Environment(CloudKitService.self) private var cloudKitService
    @Environment(AppSyncCoordinator.self) private var appSyncCoordinator
    @Environment(SyncEngine.self) private var syncEngine: SyncEngine?
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewModel: FamilyDashboardViewModel?
    @State private var showRolePicker: Bool = false
    @State private var sharePresentation: CloudSharePresentation?

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
    private let spending: any SpendingService
    private let familyRecordName: String?

    init(spending: any SpendingService, familyRecordName: String? = nil) {
        self.spending = spending
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
            .refreshable { await viewModel?.refresh(syncEngine: syncEngine) }
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
                    await viewModel?.refresh(syncEngine: syncEngine)
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
            .sheet(isPresented: $showRolePicker) {
                InviteRolePickerView { role in
                    await presentInviteShare(for: role)
                }
            }
            .sheet(item: $sharePresentation) { presentation in
                CloudSharingControllerWrapper(share: presentation.share, container: presentation.container)
            }
            .onChange(of: viewModel?.loadError) { _, newError in
                if let error = newError {
                    toastManager.show(message: error, type: .error)
                }
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
            showRolePicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.plus")
                    .font(.caption.weight(.bold))
                Text("Invite Members")
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
        .accessibilityLabel("Invite Members. Tap to invite a Hero or Co-Parent.")
    }

    @MainActor
    private func presentInviteShare(for role: UserRole) async {
        guard let share = await viewModel?.prepareInviteShare(for: role) else {
            toastManager.show(message: "Could not create an invitation. Please try again.", type: .error)
            return
        }
        sharePresentation = CloudSharePresentation(share: share, container: cloudKitService.container)
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
                            Task { @MainActor in
                                let zoneID = questService.cloudKitReference.resolvedZoneID
                                let domainLog = completion.toQuestCompletion(zoneID: zoneID)
                                if let parent = appState.currentProfile {
                                    do {
                                        _ = try await questService.reject(questLog: domainLog, by: parent)
                                        rebuild()
                                    } catch {
                                        toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                                    }
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
                            Task { @MainActor in
                                let zoneID = questService.cloudKitReference.resolvedZoneID
                                let domainLog = completion.toQuestCompletion(zoneID: zoneID)
                                if let parent = appState.currentProfile {
                                    do {
                                        _ = try await questService.verify(questLog: domainLog, by: parent)
                                        rebuild()
                                    } catch {
                                        toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                                    }
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
        // Pending payout only applies to non-real-time heroes. Real-time heroes
        // have their weekly gold disbursed immediately on each quest completion,
        // so their earnings are never "pending" a weekly batch.
        let isPending = (summary?.pendingPayoutAmount ?? 0) > 0
        // All heroes use real-time payouts: their gold is already settled and
        // ready in the wallet. No weekly batch payout applies.
        let allRealTime = summary?.heroSummaries.allSatisfy {
            $0.profile.payoutPolicyEnum == .realTime
        } ?? false
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This Week's Haul")
                        .font(.headline)
                    if allRealTime, let summary, summary.totalEarned > 0 {
                        Text("\(lootDayTitle) · Real-time Settled")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                    } else {
                        Text(isPending ? "\(lootDayTitle) · Pending Payout" : lootDayTitle)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let summary {
                    Text(summary.weekOf, format: .dateTime.month().day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary {
                totalsRow(summary: summary, isPending: isPending)

                if isPending, appState.currentProfile?.role != .hero {
                    ProcessPayoutButtonView(
                        summary: summary,
                        isProcessingPayout: isProcessingPayout,
                        onConfirmPayout: processPayout
                    )
                    .padding(.top, 4)
                }
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

    private func totalsRow(summary: WeekendSummary, isPending: Bool) -> some View {
        HStack(spacing: 12) {
            statBlock(
                icon: isPending ? "hourglass" : "banknote",
                value: CurrencyFormatter.string(summary.totalEarned),
                label: isPending ? "Pending" : "Earned",
                tint: isPending ? .orange : .gold
            )
            Divider()
            statBlock(
                icon: "checkmark.circle.fill",
                value: "\(summary.totalQuestsCompleted)",
                label: "Quests",
                tint: .green
            )
            Divider()
            statBlock(
                icon: "person.2.fill",
                value: "\(summary.heroSummaries.count)",
                label: "Heroes",
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
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func heroesSection(vm: FamilyDashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Heroes")
                    .font(.headline)
                Spacer()
                // Invites are Guild-Master-only (AD-5): only the zone owner can
                // mint a share, so Rangers see no invite affordance.
                if appState.currentProfile?.role == .guildMaster {
                    inviteButton
                }
            }
            .padding(.horizontal)

            if vm.heroes.isEmpty {
                emptyHeroesCard
            } else {
                VStack(spacing: 12) {
                    ForEach(vm.weekSummary?.heroSummaries ?? []) { summary in
                        NavigationLink {
                            HeroDetailView(hero: summary.profile, familyRecordName: familyRecordName, spending: spending)
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
                // Keep this copy in lockstep with the Invite Members button
                // gate above: only the Guild Master can mint a share, so a
                // non-GM is pointed at the Guild Master, not at a button
                // they cannot see.
                Text(appState.currentProfile?.role == .guildMaster
                    ? "Your guild needs heroes to embark on quests. Tap **Invite Members** above to invite a Hero to your guild."
                    : "Your guild needs heroes to embark on quests. Ask the Guild Master to invite a Hero to your guild.")
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
        // User-confirmed early payout: closes each open period (marks it .paid)
        // but does not retire the week's quests. Quest retirement is the
        // expired-quest sweep's job, and it only touches past weeks — never the
        // current week — so heroes keep their remaining quests mid-week.
        let zoneID = appState.family?.id.zoneID ?? familyService.cloudKitReference.resolvedZoneID
        let matchingPeriods = cachedAllowancePeriods.filter { period in
            let status = period.statusEnum
            return status == .active || status == .payoutPending
        }
        let activePeriods = matchingPeriods.map { $0.toAllowancePeriod(zoneID: zoneID) }
        for period in activePeriods {
            do {
                _ = try await treasury.runPayout(period: period)
            } catch {
                toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
            }
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
