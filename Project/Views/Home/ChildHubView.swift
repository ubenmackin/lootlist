//
//  ChildHubView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import os
import SwiftData
import SwiftUI

/// Home tab for the child role: balance hero card with bucket tiles, weekly
/// progress ring, today's chores, the active FIFO goal, and a pinned
/// log-a-purchase CTA.
struct ChildHubView: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "ChildHubView")

    @Environment(AppState.self) private var appState
    @Environment(TreasuryService.self) private var treasury
    @Environment(QuestService.self) private var questService
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?
    @Environment(CacheService.self) private var cacheService: CacheService?

    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedTemplates: [QuestTemplateCache]
    @Query private var cachedGoals: [GoalCache]
    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]
    @Query private var cachedProfiles: [ProfileCache]
    @Query private var currentProfileRows: [ProfileCache]

    @State private var viewModel: ChildHubViewModel?
    @State private var treasuryViewModel: TreasuryViewModel?
    @State private var isShowingLogSpending: Bool = false
    @State private var isShowingSplit: Bool = false
    @State private var submittingQuestIDs: Set<String> = []
    @State private var showCelebration: Bool = false
    @State private var pendingWithdrawal: PendingWithdrawal?

    struct PendingWithdrawal: Identifiable {
        let quest: QuestCache
        let log: QuestCompletionCache
        var id: String {
            quest.recordName
        }
    }

    private let spending: SpendingService
    private let familyRecordName: String?

    private let profileRecordName: String?

    init(spending: SpendingService, familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.spending = spending
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName

        // Scope queries to family at store layer; nil familyRecordName uses "" to return zero rows (no cross-family fetch).
        let targetFamily = familyRecordName ?? ""
        let targetProfile = profileRecordName ?? ""
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily }
        let templateFilter = #Predicate<QuestTemplateCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let goalFilter = #Predicate<GoalCache> { $0.familyRecordName == targetFamily }
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
        let allowanceFilter = #Predicate<AllowancePeriodCache> { $0.familyRecordName == targetFamily }
        let profileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }
        let currentProfileFilter = #Predicate<ProfileCache> {
            $0.recordName == targetProfile && $0.familyRecordName == targetFamily
        }

        _cachedQuests = Query(filter: questFilter, sort: \QuestCache.weekOf, order: .reverse)
        _cachedCompletions = Query(
            filter: completionFilter,
            sort: \QuestCompletionCache.completedDate,
            order: .reverse
        )
        _cachedTemplates = Query(filter: templateFilter, sort: \QuestTemplateCache.name)
        _cachedGoals = Query(filter: goalFilter, sort: \GoalCache.createdAt)
        _cachedLedgers = Query(filter: ledgerFilter, sort: \LedgerEntryCache.date, order: .reverse)
        _cachedAllowancePeriods = Query(filter: allowanceFilter, sort: \AllowancePeriodCache.weekOf, order: .reverse)
        _cachedProfiles = Query(filter: profileFilter, sort: \ProfileCache.displayName)
        _currentProfileRows = Query(
            filter: currentProfileFilter,
            sort: \ProfileCache.displayName
        )
    }

    /// Queried cache row for active hero profile; nil when scope has no synced row (fail-closed rendering).
    private var currentProfileRow: ProfileCache? {
        currentProfileRows.first
    }

    private var targetFamilyForFreshness: String {
        familyRecordName ?? ""
    }

    private var isSyncingPlaceholder: Bool {
        guard currentProfileRow == nil else { return false }
        guard appState.authStatus == .authenticated else { return false }
        guard !targetFamilyForFreshness.isEmpty else { return false }
        let isEmpty = cachedQuests.isEmpty && cachedProfiles.isEmpty && cachedGoals.isEmpty
        guard isEmpty else { return false }
        let isFresh = appState.cacheService?.isCacheFresh(familyRecordName: targetFamilyForFreshness, type: .profile) ?? false
        return !isFresh
    }

    private var isProfileNotFoundPlaceholder: Bool {
        guard currentProfileRow == nil else { return false }
        guard appState.authStatus == .authenticated else { return false }
        guard !targetFamilyForFreshness.isEmpty else { return false }
        return appState.cacheService?.isCacheFresh(familyRecordName: targetFamilyForFreshness, type: .profile) ?? false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystemConstants.Padding.standard) {
                    header

                    if isSyncingPlaceholder {
                        syncingBalanceCard
                    } else if isProfileNotFoundPlaceholder {
                        profileNotFoundCard
                    } else if let viewModel {
                        ChildHubBalanceSection(
                            viewModel: viewModel,
                            firstName: firstName,
                            displayName: currentProfileRow?.displayName,
                            onSplitTapped: { isShowingSplit = true }
                        )
                        ChildHubCardsView(
                            viewModel: viewModel,
                            cachedQuests: cachedQuests,
                            cachedCompletions: cachedCompletions,
                            submittingQuestIDs: submittingQuestIDs,
                            familyRecordName: familyRecordName,
                            onCompleteQuest: { quest in completeQuest(quest) },
                            onWithdraw: { quest, log in pendingWithdrawal = PendingWithdrawal(quest: quest, log: log) }
                        )
                    }
                }
                .padding(.horizontal, DesignSystemConstants.Padding.standard)
                .padding(.top, DesignSystemConstants.Padding.small)
                .padding(.bottom, DesignSystemConstants.Padding.large)
            }
            .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                await lifecycleCoordinator?.performManualSync()
            }
            .overlay {
                CelebrationOverlay(isPresented: showCelebration)
            }
            .alert(
                "Unsubmit Quest?",
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
                Button("Move Back to To-Do", role: .destructive) {
                    withdrawQuest(target.quest, log: target.log)
                }
                Button("Keep Sent for Review", role: .cancel) {
                    pendingWithdrawal = nil
                }
            } message: { target in
                Text("Move “\(target.quest.questName)” back to your active to-do list?")
            }
            .safeAreaInset(edge: .bottom) {
                logPurchaseBar
                    .padding(.horizontal, DesignSystemConstants.Padding.standard)
                    .padding(.vertical, DesignSystemConstants.Padding.small)
                    .background(Color(DesignSystemConstants.Colors.background))
            }
            .sheet(isPresented: $isShowingLogSpending) {
                if let treasuryViewModel {
                    LogSpendingView(viewModel: treasuryViewModel, familyRecordName: familyRecordName)
                }
            }
            .sheet(isPresented: $isShowingSplit) {
                SavingsSplitView(
                    familyRecordName: familyRecordName,
                    profileRecordName: profileRecordName ?? appState.currentProfile?.id.recordName
                )
            }
            .task { ensureViewModels() }
            .onChange(of: cachedQuests) { _, _ in rebuild() }
            .onChange(of: cachedCompletions) { _, _ in rebuild() }
            .onChange(of: cachedTemplates) { _, _ in rebuild() }
            .onChange(of: cachedGoals) { _, _ in rebuild() }
            .onChange(of: cachedLedgers) { _, _ in rebuild() }
            .onChange(of: cachedAllowancePeriods) { _, _ in rebuild() }
            .onChange(of: cachedProfiles) { _, _ in rebuild() }
            .onChange(of: currentProfileRows) { _, _ in rebuild() }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if isSyncingPlaceholder {
            VStack(spacing: 8) {
                ProgressView()
                Text("Syncing your family...")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Syncing your family")
            .accessibilityIdentifier("hub.syncingPlaceholder")
        } else if isProfileNotFoundPlaceholder {
            VStack(spacing: 8) {
                Text("Profile not found — pull to refresh")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await lifecycleCoordinator?.performManualSync() }
                } label: {
                    Text("Retry")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry sync")
                .accessibilityIdentifier("hub.retryButton")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Profile not found — pull to refresh")
            .accessibilityIdentifier("hub.profileNotFoundPlaceholder")
        } else if let row = currentProfileRow {
            HStack(spacing: DesignSystemConstants.Padding.medium) {
                Text(row.avatarEmoji ?? "🦸")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.15)))
                    .overlay(Circle().strokeBorder(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.3), lineWidth: 1))

                if let name = firstName {
                    Text("\(name)'s Hub")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else {
                    Text("\(row.displayName)'s Hub")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(firstName ?? row.displayName)'s Hub")
            .accessibilityIdentifier("hub.headerTitle")
        } else {
            HStack(spacing: DesignSystemConstants.Padding.medium) {
                Text("🦸")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.15)))
                    .overlay(Circle().strokeBorder(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.3), lineWidth: 1))

                Text("Your Hub")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Your Hub")
            .accessibilityIdentifier("hub.headerTitle")
        }
    }

    private var firstName: String? {
        guard let name = currentProfileRow?.displayName, !name.isEmpty else { return nil }
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    private var syncingBalanceCard: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Syncing your family...")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(DesignSystemConstants.Padding.large)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Syncing your family")
        .accessibilityIdentifier("hub.syncingBalanceCard")
    }

    private var profileNotFoundCard: some View {
        VStack(spacing: 16) {
            Text("Profile not found — pull to refresh")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await lifecycleCoordinator?.performManualSync() }
            } label: {
                Text("Retry")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry sync")
            .accessibilityIdentifier("hub.retryButtonCard")
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(DesignSystemConstants.Padding.large)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Profile not found — pull to refresh")
        .accessibilityIdentifier("hub.profileNotFoundCard")
    }

    // MARK: - Log-a-Purchase CTA

    private var logPurchaseBar: some View {
        Button {
            HapticsService.lightImpact()
            isShowingLogSpending = true
        } label: {
            Label("Log a Purchase / Spend", systemImage: "cart.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.button, style: .continuous)
                        .fill(Color(DesignSystemConstants.Colors.primaryGreen))
                )
        }
        .accessibilityHint("Opens the spending log form")
        .accessibilityIdentifier("hub.logPurchaseButton")
    }

    // MARK: - Rebuild

    private func ensureViewModels() {
        let vm = ViewLifecycle.ensure(&viewModel, factory: {
            ChildHubViewModel(
                appState: appState,
                cacheService: cacheService ?? appState.cacheService
            )
        })
        let tvm = ViewLifecycle.ensure(&treasuryViewModel, factory: {
            TreasuryViewModel(
                treasury: treasury,
                spending: spending,
                appState: appState
            )
        })
        rebuild(vm, tvm)
    }

    private func rebuild(_ vm: ChildHubViewModel? = nil, _ tvm: TreasuryViewModel? = nil) {
        appState.updateCurrentProfileFromCache()
        guard let profileName = appState.currentProfile?.id.recordName else { return }

        (vm ?? viewModel)?.rebuild(
            quests: cachedQuests,
            logs: cachedCompletions,
            templates: cachedTemplates,
            goals: cachedGoals
        )

        // Keep spending-sheet view model synced for live balances on Log a Purchase (mirrors Money tab).
        if let treasury = tvm ?? treasuryViewModel {
            treasury.rebuildLists(
                logs: cachedCompletions.filter { $0.completerRecordName == profileName },
                ledgers: cachedLedgers.filter { $0.profileRecordName == profileName },
                quests: cachedQuests.filter { $0.assigneeRecordName == profileName },
                allowancePeriods: cachedAllowancePeriods.filter { $0.profileRecordName == profileName },
                scope: .thisWeek
            )
        }
    }

    // MARK: - Quest Actions

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
            guard let profile = appState.currentProfile else { return }

            let zoneID = appState.resolvedFamilyZoneID()
            let domain = quest.toQuest(zoneID: zoneID)

            do {
                let completion = try await questService.markComplete(
                    quest: domain,
                    by: profile
                )
                if completion.verificationStatus == .autoApproved {
                    HapticsService.success()
                    showCelebration = true
                    Task {
                        do {
                            try await Task.sleep(for: .seconds(DesignSystemConstants.Celebration.confettiLifetime))
                        } catch {
                            Self.logger.debug("Celebration dismiss sleep interrupted: \(error, privacy: .private)")
                        }
                        showCelebration = false
                    }
                }
            } catch {
                Self.logger.error("Failed to mark quest complete: \(error, privacy: .private)")
            }
        }
    }
}
