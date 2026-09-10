//
//  FamilyDashboardViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import Foundation
import Observation
import os

// ViewModels never hold `any CloudKitServiceProtocol` directly — they route
// through `FamilyService`/`TreasuryService` and related coordinators. This is
// a compile-time convention check: grep for `CloudKitServiceProtocol` in
// `Project/ViewModels` must return no matches.

/// WHY typed signal: roster changes previously rode a stringly-typed channel with
/// the family name as untyped object, so observers ride an AsyncStream bus.
/// The reconciler post remains as a legacy ingress adapter until it emits directly.
@MainActor
final class RosterChangeSignal {
    private static var continuations: [UUID: AsyncStream<String>.Continuation] = [:]

    static func emit(familyRecordName: String = "") {
        for (_, continuation) in continuations {
            continuation.yield(familyRecordName)
        }
    }

    static func stream() -> AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await MainActor.run { continuations.removeValue(forKey: id) } }
            }
        }
    }
}

@MainActor
@Observable
final class FamilyDashboardViewModel {
    private(set) var heroes: [ProfileCache] = []

    private(set) var parents: [ProfileCache] = []

    /// Share participants and pending invites shown in the Invitations panel.
    private(set) var invitations: [FamilyInvitation] = []

    private(set) var weekSummary: WeekendSummary?

    private(set) var pastPayouts: [AllowancePeriodCache] = []

    /// Sum of all child ledger balances across the family (whole pennies).
    private(set) var familyOutflow: Int64 = 0

    /// Count of quest completions awaiting parent verification.
    private(set) var pendingReviewCount: Int = 0

    /// Per-child card data for the dashboard grid.
    private(set) var childAccountCards: [ChildAccountCard] = []

    private(set) var isLoading: Bool = false

    var loadError: String?

    private let questService: QuestService
    private let treasury: TreasuryService
    private let achievements: AchievementService
    private let familyService: any FamilyProfileFetching
    private let appState: AppState
    private let logger = Logger(category: "FamilyDashboard")

    /// Mirrors TreasuryService toast manager to surface breakdown errors in toast banner.
    var toastManager: ToastManager? {
        treasury.toastManager
    }

    /// Invitation orchestration is owned by `FamilyInvitationCoordinator` behind
    /// `FamilyInviting` so this ViewModel stays pure `rebuildLists` + bindings.
    private let invitationCoordinator: any FamilyInviting
    private let syncCoordinator: (any SyncEnqueuing)?
    private let lifecycleCoordinator: AppLifecycleCoordinator?

    /// WHY dedicated host: sync subscription lives off the ViewModel so @Query pulses stay pure rebuilds.
    private let syncHost = DashboardSyncHost()

    @ObservationIgnored private var lastRebuildKey: Int?
    @ObservationIgnored private var lastRebuildMetrics: DashboardMetricsCalculator.Metrics?
    /// WHY cache-first: viewer gating mirrors the queried row so session drift never leaks into the dashboard.
    @ObservationIgnored private var cachedViewerRole: UserRole?

    init(questService: QuestService,
         treasury: TreasuryService,
         achievementService: AchievementService,
         familyService: any FamilyProfileFetching,
         appState: AppState,
         invitationCoordinator: (any FamilyInviting)? = nil,
         syncCoordinator: (any SyncEnqueuing)? = nil,
         lifecycleCoordinator: AppLifecycleCoordinator? = nil)
    {
        self.questService = questService
        self.treasury = treasury
        achievements = achievementService
        self.familyService = familyService
        self.appState = appState
        self.invitationCoordinator = invitationCoordinator
            ?? FamilyInvitationCoordinator(familyService: familyService, appState: appState)
        let resolvedSync: (any SyncEnqueuing)? = syncCoordinator ?? (familyService as? FamilyService)?.syncCoordinator
        self.syncCoordinator = resolvedSync
        self.lifecycleCoordinator = lifecycleCoordinator
    }

    /// Observes roster changes to refresh invitations when members join or leave.
    func startRosterObserver() {
        syncHost.startRosterObserver(viewModel: self)
    }

    /// Stops the roster-change observer started by `startRosterObserver()`.
    func stopRosterObserver() {
        syncHost.stopRosterObserver()
    }

    func refresh() async {
        guard appState.family != nil else {
            heroes = []
            parents = []
            weekSummary = nil
            return
        }

        isLoading = true
        defer { isLoading = false }

        if let family = appState.family {
            await requestProfileSync(for: family)
            do {
                try await achievements.seedDefaultAchievements(family: family)
            } catch {
                logger.warning("Default achievements seed skipped: \(error, privacy: .private)")
            }
        }
    }

    private func requestProfileSync(for family: Family) async {
        // WHY lifecycle-only: dashboard refresh rides the single-flight gate so reconciliation never bypasses ingest.
        guard !family.id.recordName.isEmpty else { return }
        guard let lifecycleCoordinator else { return }
        await lifecycleCoordinator.performManualSync()
    }

    /// Resolves role-specific share presentation via the invitation coordinator (zone owner only).
    func prepareInviteShare(for role: UserRole) async -> CloudSharePresentation? {
        await invitationCoordinator.prepareInviteShare(for: role)
    }

    /// Reloads and classifies invitation statuses via the coordinator.
    func refreshInvitations() async {
        invitations = await invitationCoordinator.refreshInvitations(
            heroes: heroes,
            parents: parents
        )
    }

    /// Revokes a pending invitation or departed member's share access via the coordinator.
    func revokeInvitation(_ invitation: FamilyInvitation) async {
        do {
            try await invitationCoordinator.revokeInvitation(invitation)
            invitations.removeAll { $0.id == invitation.id }
        } catch {
            logger.error("Failed to revoke invitation: \(error, privacy: .private)")
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // WHY single path: toast when wired, loadError fallback so previews never fail silently.
            report(message: message, type: .error)
        }
    }

    /// Synchronous rebuild from SwiftData `@Query` rows using pure cache math.
    /// Delegates roster sorting to `RosterViewState` and all metric derivations to
    /// `DashboardMetricsCalculator` so each concern is independently testable.
    /// DashboardMetricsCalculator centralizes ledger attribution via `BucketService.applyBucketAttribution`
    /// and `BucketService.bucketBalances` so familyOutflow and childAccountCards never re-implement bucket math.
    @MainActor
    func rebuildLists(
        profiles: [ProfileCache],
        quests: [QuestCache],
        logs: [QuestCompletionCache],
        ledgers: [LedgerEntryCache],
        allowancePeriods: [AllowancePeriodCache],
        profileAchievements: [ProfileAchievementCache],
        achievements: [AchievementCache],
        templates: [QuestTemplateCache],
        familyRow: FamilyCache? = nil,
        viewerRow: ProfileCache? = nil
    ) {
        let roster = RosterViewState(profiles: profiles)
        heroes = roster.heroes
        parents = roster.parents
        if let viewerRow {
            cachedViewerRole = viewerRow.roleEnum
        }

        // WHY cache-first: context mirrors queried rows so payout math never disagrees with view gating.
        let resolvedFamilyName = familyRow?.recordName ?? appState.family?.id.recordName
        let resolvedPayoutDay: PayoutDay
        let resolvedPayoutPolicy: PayoutPolicy?
        if familyRow != nil || viewerRow != nil {
            resolvedPayoutDay = PayoutDayResolver.resolved(for: viewerRow, family: familyRow)
            resolvedPayoutPolicy = familyRow?.payoutPolicyEnum
        } else {
            resolvedPayoutDay = PayoutDayResolver.resolved(for: nil as Profile?, family: appState.family)
            resolvedPayoutPolicy = appState.family?.payoutPolicy
        }
        let familyContext = DashboardMetricsCalculator.FamilyContext(
            recordName: resolvedFamilyName,
            payoutDay: resolvedPayoutDay,
            payoutPolicy: resolvedPayoutPolicy
        )

        // WHY memoize: @Query refires on unrelated writes, so trophy-bearing metrics reuse the last pass unless inputs change.
        // WHY snapshots: live rows map to Sendable copies on isolation before hashing, so the fingerprinter never faults.
        let rebuildKey = DashboardMetricsFingerprinter.rebuildKey(
            .init(
                profiles: profiles.map(DashboardProfileSnapshot.init(from:)),
                quests: quests.map(DashboardQuestSnapshot.init(from:)),
                logs: logs.map(DashboardCompletionSnapshot.init(from:)),
                ledgers: ledgers.map(DashboardLedgerSnapshot.init(from:)),
                allowancePeriods: allowancePeriods.map(DashboardPeriodSnapshot.init(from:)),
                profileAchievements: profileAchievements.map(DashboardProfileAchievementSnapshot.init(from:)),
                achievements: achievements.map(DashboardAchievementSnapshot.init(from:)),
                templates: templates.map(DashboardTemplateSnapshot.init(from:)),
                familyContext: familyContext,
                freshnessVersion: appState.cacheService?.freshnessVersion ?? 0
            )
        )
        if let cached = lastRebuildMetrics, rebuildKey == lastRebuildKey {
            weekSummary = cached.weekSummary
            pastPayouts = cached.pastPayouts
            familyOutflow = cached.familyOutflow
            pendingReviewCount = cached.pendingReviewCount
            childAccountCards = cached.childAccountCards
            if loadError != nil {
                loadError = nil
            }
            return
        }

        let metrics = DashboardMetricsCalculator.calculate(
            profiles: profiles,
            quests: quests,
            logs: logs,
            ledgers: ledgers,
            allowancePeriods: allowancePeriods,
            profileAchievements: profileAchievements,
            familyContext: familyContext,
            templates: templates
        )

        lastRebuildKey = rebuildKey
        lastRebuildMetrics = metrics
        weekSummary = metrics.weekSummary
        pastPayouts = metrics.pastPayouts
        familyOutflow = metrics.familyOutflow
        pendingReviewCount = metrics.pendingReviewCount
        childAccountCards = metrics.childAccountCards

        if loadError != nil {
            loadError = nil
        }
    }

    /// WHY explicit bust: purge/clear deletes memo-held rows, so callers drop the key alongside reset.
    func invalidateMemo() {
        lastRebuildKey = nil
        lastRebuildMetrics = nil
        cachedViewerRole = nil
    }

    /// WHY cache-first: viewer gating mirrors the queried row so session drift never leaks into the dashboard.
    var isGuildMaster: Bool {
        if let cachedViewerRole {
            return cachedViewerRole == .guildMaster
        }
        return appState.currentProfile?.role == .guildMaster
    }

    // MARK: - Section Transforms (pure, no CloudKit)

    /// WHY ViewModel-owned: six-week trend math lived in the view body;
    /// one helper keeps dashboard sparkline and payout charts identical.
    nonisolated static func sparklinePoints(
        periods: [AllowancePeriodCache],
        payoutDay: PayoutDay,
        selectedProfile: String?,
        now: Date = Date()
    ) -> [WeeklyEarningPoint] {
        HubQueryProvider.weeklyEarningPoints(periods: periods, payoutDay: payoutDay, selectedProfile: selectedProfile, now: now)
    }

    nonisolated static func sparklineTotal(for points: [WeeklyEarningPoint]) -> Int64 {
        points.reduce(0) { $0 + $1.amount }
    }

    /// Pending-review completions shared by the stat card and queue section.
    nonisolated static func pendingCompletions(from completions: [QuestCompletionCache]) -> [QuestCompletionCache] {
        HubQueryProvider.pendingCompletions(from: completions)
    }

    /// Weekly subtitle shared by the summary card header.
    nonisolated static func weeklySubtitle(lootDayTitle: String, isPending: Bool, showsSettled: Bool) -> String {
        if showsSettled {
            return "\(lootDayTitle) · Real-time Settled"
        }
        if isPending {
            return "\(lootDayTitle) · Pending Payout"
        }
        return lootDayTitle
    }

    func subscribeToSyncEvents(_ coordinator: AppSyncCoordinator) {
        syncHost.subscribe(viewModel: self, coordinator: coordinator)
    }

    func unsubscribeFromSyncEvents(_ coordinator: AppSyncCoordinator) {
        syncHost.unsubscribe(coordinator: coordinator)
    }

    func reset() {
        heroes = []
        parents = []
        weekSummary = nil
        pastPayouts = []
        loadError = nil
        isLoading = false
        invalidateMemo()
    }
}

/// WHY single path: toast when wired, loadError fallback so previews never fail silently.
extension FamilyDashboardViewModel: ToastReporting {
    func setReportMessage(_ message: String) {
        loadError = message
    }
}

/// WHY dedicated host: sync subscription and roster observation live off the ViewModel so rebuilds stay pure.
@MainActor
@Observable
final class DashboardSyncHost {
    private var syncSubscriptionID: UUID?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var rosterTask: Task<Void, Never>?

    func subscribe(viewModel: FamilyDashboardViewModel, coordinator: AppSyncCoordinator) {
        guard syncSubscriptionID == nil else { return }
        let (stream, id) = coordinator.subscribe()
        syncSubscriptionID = id
        syncTask = Task { [weak self, weak viewModel] in
            for await event in stream {
                guard let self, let viewModel else { return }
                // WHY hop: stream resumes off isolation, so awaiting re-enters MainActor before touching view state.
                switch event {
                case .recordChanged:
                    self.handleRecordChangedSync()
                case .shareAccepted, .zoneReset:
                    await viewModel.refresh()
                }
            }
        }
        startRosterObserver(viewModel: viewModel)
    }

    private func handleRecordChangedSync() {
        // CKSyncEngine handles incoming pushes into SwiftData, which re-fires @Query into rebuildLists.
    }

    func unsubscribe(coordinator: AppSyncCoordinator) {
        syncTask?.cancel()
        syncTask = nil
        if let id = syncSubscriptionID {
            coordinator.unsubscribe(id: id)
            syncSubscriptionID = nil
        }
        stopRosterObserver()
    }

    func startRosterObserver(viewModel: FamilyDashboardViewModel) {
        guard rosterTask == nil else { return }
        let signalStream = RosterChangeSignal.stream()
        // WHY discarding group: the typed signal and its legacy bridge share one
        // cancellable scope so stop cancels both without per-task locks.
        rosterTask = Task { [weak viewModel] in
            await withDiscardingTaskGroup { group in
                group.addTask { [weak viewModel] in
                    for await _ in signalStream {
                        guard !Task.isCancelled else { break }
                        guard let viewModel else { break }
                        // WHY hop: signal sequence resumes off isolation, so awaiting re-enters MainActor before touching view state.
                        await viewModel.refreshInvitations()
                    }
                }
                group.addTask {
                    // WHY legacy ingress: the reconciler still posts NotificationCenter,
                    // so forward into the typed bus for single-path handling.
                    for await notification in NotificationCenter.default.notifications(named: .familyRosterChanged) {
                        guard !Task.isCancelled else { break }
                        let recordName = notification.object as? String ?? ""
                        await MainActor.run { RosterChangeSignal.emit(familyRecordName: recordName) }
                    }
                }
            }
        }
    }

    func stopRosterObserver() {
        rosterTask?.cancel()
        rosterTask = nil
    }

    deinit {
        rosterTask?.cancel()
        syncTask?.cancel()
    }
}

struct WeekendSummary: Equatable {
    let weekOf: Date

    /// Whole pennies.
    let totalEarned: Int64

    /// Quest gold awaiting weekly payout settlement for non-real-time heroes.
    var pendingPayoutAmount: Int64 {
        heroSummaries.reduce(into: 0) { acc, hero in
            if (hero.profile.payoutPolicyEnum ?? .perQuest) != .realTime {
                acc += hero.weeklyQuestGold
            }
        }
    }

    let totalQuestsCompleted: Int

    let heroSummaries: [HeroSummary]
}

extension WeekendSummary {
    var totalQuestsAssigned: Int {
        heroSummaries.reduce(into: 0) { $0 += $1.weeklyQuestsTotal }
    }
}

struct HeroSummary: Equatable, Identifiable {
    var id: String {
        profile.recordName
    }

    let profile: ProfileCache

    let weeklyQuestsCompleted: Int

    let weeklyQuestsTotal: Int

    /// Total earned this week for display (quest gold + immediate bonus like deposits).
    let weeklyGoldEarned: Int64

    /// Quest gold only — the portion that is pending payout for non-real-time heroes.
    /// Deposits/withdrawals hit the ledger immediately and must not be pending.
    let weeklyQuestGold: Int64

    let currentStreak: Int

    let trophiesEarned: Int

    var avatarRenderSpec: AvatarRenderSpec?

    init(
        profile: ProfileCache,
        weeklyQuestsCompleted: Int,
        weeklyQuestsTotal: Int,
        weeklyGoldEarned: Int64,
        weeklyQuestGold: Int64? = nil,
        currentStreak: Int,
        trophiesEarned: Int,
        avatarRenderSpec: AvatarRenderSpec? = nil
    ) {
        self.profile = profile
        self.weeklyQuestsCompleted = weeklyQuestsCompleted
        self.weeklyQuestsTotal = weeklyQuestsTotal
        self.weeklyGoldEarned = weeklyGoldEarned
        // Backwards compat: when called without quest-specific gold, treat total as quest gold (older tests).
        self.weeklyQuestGold = weeklyQuestGold ?? weeklyGoldEarned
        self.currentStreak = currentStreak
        self.trophiesEarned = trophiesEarned
        self.avatarRenderSpec = avatarRenderSpec
    }
}

/// Redacted share participant shown in the Invitations panel for status and revocation.
/// CKShare stays in the Service layer; this is a presentation-only model.
struct FamilyInvitation: Identifiable {
    let id: String
    let identity: String
    let statusText: String
    let identityRecordName: String?
    let identityKey: String?
    let kind: FamilyInvitationKind
    let targetRole: UserRole?
    let isOwner: Bool

    init(
        id: String,
        identity: String,
        statusText: String,
        identityRecordName: String?,
        kind: FamilyInvitationKind,
        targetRole: UserRole? = nil,
        isOwner: Bool = false,
        identityKey: String? = nil
    ) {
        self.id = id
        self.identity = identity
        self.statusText = statusText
        self.identityRecordName = identityRecordName
        self.identityKey = identityKey
        self.kind = kind
        self.targetRole = targetRole
        self.isOwner = isOwner
    }
}

/// How an Invitations-panel row should be presented. Explicit `Equatable` so
/// row-kind comparisons in the panel and its tests stay compile-time stable.
enum FamilyInvitationKind: Equatable {
    /// A not-yet-member invite: pending or accepted on the share, with no
    /// active `Profile` yet. The Guild Master can revoke it.
    case pendingInvite
    /// Deactivated member whose share access is pending owner-side revocation.
    case departedMember
    /// An identity the Guild Master already revoked; CloudKit keeps it visible
    /// on the share with `.removed` status until propagation completes.
    /// Read-only row.
    case removedIdentity
}

/// Per-child dashboard card data — balance and pending review count are
/// computed from the same cached ledger/completion queries that feed the
/// rest of the dashboard, so this is zero-additional-query metadata.
struct ChildAccountCard: Identifiable, Equatable {
    var id: String {
        profile.recordName
    }

    let profile: ProfileCache
    let balance: Int64
    let pendingReviewCount: Int
}
