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

@MainActor
@Observable
final class FamilyDashboardViewModel {
    private(set) var heroes: [ProfileCache] = []

    private(set) var parents: [ProfileCache] = []

    /// Share participants and pending invites shown in the Invitations panel.
    private(set) var invitations: [FamilyInvitation] = []

    private(set) var weekSummary: WeekendSummary?

    private(set) var pastPayouts: [AllowancePeriodCache] = []

    /// Sum of all child ledger balances across the family.
    private(set) var familyOutflow: Double = 0

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
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "FamilyDashboard")

    /// Mirrors TreasuryService toast manager to surface breakdown errors in toast banner.
    var toastManager: ToastManager? {
        treasury.toastManager
    }

    /// Invitation orchestration is owned by `FamilyInvitationCoordinator` behind
    /// `FamilyInviting` so this ViewModel stays pure `rebuildLists` + bindings.
    private let invitationCoordinator: any FamilyInviting

    private var syncSubscriptionID: UUID?
    private var syncTask: Task<Void, Never>?

    /// Observer for roster changes to refresh invitations when membership updates.
    @ObservationIgnored private var rosterObserverTask: Task<Void, Never>?

    init(questService: QuestService,
         treasury: TreasuryService,
         achievementService: AchievementService,
         familyService: any FamilyProfileFetching,
         appState: AppState,
         invitationCoordinator: (any FamilyInviting)? = nil)
    {
        self.questService = questService
        self.treasury = treasury
        achievements = achievementService
        self.familyService = familyService
        self.appState = appState
        self.invitationCoordinator = invitationCoordinator
            ?? FamilyInvitationCoordinator(familyService: familyService, appState: appState)
    }

    /// Observes roster changes to refresh invitations when members join or leave.
    func startRosterObserver() {
        guard rosterObserverTask == nil else { return }
        rosterObserverTask = Task { @MainActor [weak self] in
            #if DEBUG
                assert(Thread.isMainThread, "startRosterObserver must hop to MainActor")
            #endif
            await withTaskCancellationHandler {
                for await _ in NotificationCenter.default.notifications(named: .familyRosterChanged) {
                    guard !Task.isCancelled else { break }
                    guard let self else { break }
                    #if DEBUG
                        assert(Thread.isMainThread)
                    #endif
                    await self.refreshInvitations()
                }
            } onCancel: {}
        }
    }

    /// Stops the roster-change observer started by `startRosterObserver()`.
    func stopRosterObserver() {
        rosterObserverTask?.cancel()
        rosterObserverTask = nil
    }

    deinit {
        rosterObserverTask?.cancel()
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
            await familyService.refreshProfilesFromCloudKit(for: family)
            do {
                try await achievements.seedDefaultAchievements(family: family)
            } catch {
                logger.warning("Default achievements seed skipped: \(error, privacy: .private)")
            }
        }
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
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
        achievements _: [AchievementCache]
    ) {
        let roster = RosterViewState(profiles: profiles)
        heroes = roster.heroes
        parents = roster.parents

        let familyContext = DashboardMetricsCalculator.FamilyContext(
            recordName: appState.family?.id.recordName,
            payoutDay: PayoutDayResolver.resolved(for: nil as Profile?, family: appState.family),
            payoutPolicy: appState.family?.payoutPolicy
        )

        let metrics = DashboardMetricsCalculator.calculate(
            profiles: profiles,
            quests: quests,
            logs: logs,
            ledgers: ledgers,
            allowancePeriods: allowancePeriods,
            profileAchievements: profileAchievements,
            familyContext: familyContext
        )

        weekSummary = metrics.weekSummary
        pastPayouts = metrics.pastPayouts
        familyOutflow = metrics.familyOutflow
        pendingReviewCount = metrics.pendingReviewCount
        childAccountCards = metrics.childAccountCards

        if loadError != nil {
            loadError = nil
        }
    }

    var isGuildMaster: Bool {
        appState.currentProfile?.role == .guildMaster
    }

    func subscribeToSyncEvents(_ coordinator: AppSyncCoordinator) {
        guard syncSubscriptionID == nil else { return }
        let (stream, id) = coordinator.subscribe()
        syncSubscriptionID = id
        syncTask = Task { @MainActor [weak self] in
            #if DEBUG
                assert(Thread.isMainThread, "subscribeToSyncEvents must hop to MainActor")
            #endif
            for await event in stream {
                guard let self else { return }
                #if DEBUG
                    assert(Thread.isMainThread)
                #endif
                switch event {
                case .recordChanged:
                    handleRecordChangedSync()
                case .shareAccepted, .zoneReset:
                    await refresh()
                }
            }
        }
        // WHY: the roster observer must start post-init on the MainActor —
        // started during init, its task could escape before every stored
        // property is initialized.
        startRosterObserver()
    }

    @MainActor
    private func handleRecordChangedSync() {
        // CKSyncEngine (via `CKSyncEngineDelegateHandler`) handles writing
        // incoming push changes to SwiftData, which automatically re-fires
        // `.onChange` → `rebuildLists()`.
    }

    func unsubscribeFromSyncEvents(_ coordinator: AppSyncCoordinator) {
        syncTask?.cancel()
        syncTask = nil
        if let id = syncSubscriptionID {
            coordinator.unsubscribe(id: id)
            syncSubscriptionID = nil
        }
        stopRosterObserver()
    }

    func reset() {
        heroes = []
        parents = []
        weekSummary = nil
        pastPayouts = []
        loadError = nil
        isLoading = false
    }
}

struct WeekendSummary: Equatable {
    let weekOf: Date

    let totalEarned: Double

    /// Quest gold awaiting weekly payout settlement for non-real-time heroes.
    var pendingPayoutAmount: Double {
        heroSummaries.reduce(into: 0.0) { acc, hero in
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
    let weeklyGoldEarned: Double

    /// Quest gold only — the portion that is pending payout for non-real-time heroes.
    /// Deposits/withdrawals hit the ledger immediately and must not be pending.
    let weeklyQuestGold: Double

    let currentStreak: Int

    let trophiesEarned: Int

    var avatarRenderSpec: AvatarRenderSpec?

    init(
        profile: ProfileCache,
        weeklyQuestsCompleted: Int,
        weeklyQuestsTotal: Int,
        weeklyGoldEarned: Double,
        weeklyQuestGold: Double? = nil,
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
        isOwner: Bool = false
    ) {
        self.id = id
        self.identity = identity
        self.statusText = statusText
        self.identityRecordName = identityRecordName
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
    let balance: Double
    let pendingReviewCount: Int
}
