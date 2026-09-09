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

    private var syncSubscriptionID: UUID?
    private var syncTask: Task<Void, Never>?

    /// Observer for roster changes to refresh invitations when membership updates.
    @ObservationIgnored private var rosterObserverTask: Task<Void, Never>?

    @ObservationIgnored private var lastRebuildKey: String?
    @ObservationIgnored private var lastRebuildMetrics: DashboardMetricsCalculator.Metrics?
    /// WHY cache-first: viewer gating mirrors the queried row so session drift never leaks into the dashboard.
    @ObservationIgnored private var cachedViewerRole: UserRole?

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
        rosterObserverTask = Task { [weak self] in
            await withTaskCancellationHandler {
                for await _ in NotificationCenter.default.notifications(named: .familyRosterChanged) {
                    guard !Task.isCancelled else { break }
                    guard let self else { break }
                    // WHY hop: notification sequence resumes off isolation, so awaiting re-enters MainActor before touching view state.
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
        let rebuildKey = Self.rebuildKey(
            inputs: RebuildInputs(
                profiles: profiles,
                quests: quests,
                logs: logs,
                ledgers: ledgers,
                allowancePeriods: allowancePeriods,
                profileAchievements: profileAchievements,
                achievements: achievements,
                templates: templates
            ),
            familyContext: familyContext,
            freshnessVersion: appState.cacheService?.freshnessVersion ?? 0
        )
        if let cached = lastRebuildMetrics, rebuildKey == lastRebuildKey, Self.isMemoLive(cached) {
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

    /// WHY bundled inputs: keeps the memo key builder within the parameter-count limit.
    private struct RebuildInputs {
        let profiles: [ProfileCache]
        let quests: [QuestCache]
        let logs: [QuestCompletionCache]
        let ledgers: [LedgerEntryCache]
        let allowancePeriods: [AllowancePeriodCache]
        let profileAchievements: [ProfileAchievementCache]
        let achievements: [AchievementCache]
        let templates: [QuestTemplateCache]
    }

    /// WHY full fingerprint: every field feeding week math or balances busts the memo on in-place edits.
    private static func rebuildKey(
        inputs: RebuildInputs,
        familyContext: DashboardMetricsCalculator.FamilyContext,
        freshnessVersion: Int
    ) -> String {
        let profilePart: String = join(inputs.profiles.map { fingerprint(for: $0) }.sorted(), separator: ",")
        let questPart: String = join(inputs.quests.map { fingerprint(for: $0) }.sorted(), separator: ",")
        let logPart: String = join(inputs.logs.map { fingerprint(for: $0) }.sorted(), separator: ",")
        let ledgerPart: String = join(inputs.ledgers.map { fingerprint(for: $0) }.sorted(), separator: ",")
        let periodPart: String = join(inputs.allowancePeriods.map { fingerprint(for: $0) }.sorted(), separator: ",")
        let profileAchievementPart: String = join(inputs.profileAchievements.map { fingerprint(for: $0) }.sorted(), separator: ",")
        let achievementPart: String = join(inputs.achievements.map { fingerprint(for: $0) }.sorted(), separator: ",")
        let templatePart: String = join(inputs.templates.map { fingerprint(for: $0) }.sorted(), separator: ",")
        let contextPart: String = fingerprint(familyContext: familyContext, freshnessVersion: freshnessVersion)
        let parts: [String] = [profilePart, questPart, logPart, ledgerPart, periodPart, profileAchievementPart, achievementPart, templatePart, contextPart]
        return join(parts, separator: "|")
    }

    /// WHY one join: every fingerprint shares separators so memo keys never drift.
    private static func join(_ fields: [String], separator: String = ":") -> String {
        fields.joined(separator: separator)
    }

    /// WHY tiny fingerprints: one row types alone so the checker never solves a mega-interpolation.
    private static func fingerprint(for profile: ProfileCache) -> String {
        let recordName: String = profile.recordName
        let family: String = profile.familyRecordName
        let displayName: String = profile.displayName
        let role: String = profile.role
        let active = String(describing: profile.isActive)
        let payoutDay: String = profile.payoutDay ?? "-"
        let payoutPolicy: String = profile.payoutPolicy ?? "-"
        let avatarName: String = profile.avatarName ?? "-"
        let avatarEmoji: String = profile.avatarEmoji ?? "-"
        let avatarClass: String = profile.avatarClass ?? "-"
        let splitSpend = String(profile.splitPercentSpend)
        let splitShort = String(profile.splitPercentShort)
        let splitLong = String(profile.splitPercentLong)
        let fields: [String] = [recordName, family, displayName, role, active, payoutDay, payoutPolicy, avatarName, avatarEmoji, avatarClass, splitSpend, splitShort, splitLong]
        return join(fields)
    }

    /// WHY tiny fingerprints: one row types alone so the checker never solves a mega-interpolation.
    private static func fingerprint(for quest: QuestCache) -> String {
        let recordName: String = quest.recordName
        let family: String = quest.familyRecordName
        let assignee: String = quest.assigneeRecordName
        let template: String = quest.templateRecordName
        let week = String(Int(quest.weekOf.timeIntervalSince1970))
        let gold = String(quest.goldReward)
        let xp = String(quest.xpReward)
        let target = String(quest.targetCount)
        let schedule: String = quest.scheduleType
        let allOrNothing = String(describing: quest.isAllOrNothing)
        let active = String(describing: quest.isActive)
        let questName: String = quest.questName
        let claimer: String = quest.claimedByProfileRecordName ?? "-"
        let claimedAtValue: Int = if let claimedAt = quest.claimedAt {
            Int(claimedAt.timeIntervalSince1970)
        } else {
            -1
        }
        let claimedAt = String(claimedAtValue)
        let details: String = quest.descriptionText ?? "-"
        let fields: [String] = [recordName, family, assignee, template, week, gold, xp, target, schedule, allOrNothing, active, questName, claimer, claimedAt, details]
        return join(fields)
    }

    /// WHY tiny fingerprints: one row types alone so the checker never solves a mega-interpolation.
    private static func fingerprint(for log: QuestCompletionCache) -> String {
        let recordName: String = log.recordName
        let family: String = log.familyRecordName
        let quest: String = log.questRecordName
        let completer: String = log.completerRecordName
        let week = String(Int(log.weekOf.timeIntervalSince1970))
        let completed = String(Int(log.completedDate.timeIntervalSince1970))
        let status: String = log.verificationStatus
        let approval: String = log.approvalMode
        // WHY metrics-only: verifier and credit markers never feed counts, so only routing fields bust.
        let fields: [String] = [recordName, family, quest, completer, week, completed, status, approval]
        return join(fields)
    }

    /// WHY tiny fingerprints: one row types alone so the checker never solves a mega-interpolation.
    private static func fingerprint(for entry: LedgerEntryCache) -> String {
        let recordName: String = entry.recordName
        let family: String = entry.familyRecordName
        let profile: String = entry.profileRecordName
        let amount = String(entry.amount)
        let source: String = entry.source
        let bucket: String = entry.bucketKind ?? "-"
        let fromBucket: String = entry.fromBucket ?? "-"
        let toBucket: String = entry.toBucket ?? "-"
        let date = String(Int(entry.date.timeIntervalSince1970))
        // WHY metrics-only: description and location never feed balances, so only money fields bust.
        let fields: [String] = [recordName, family, profile, amount, source, bucket, fromBucket, toBucket, date]
        return join(fields)
    }

    /// WHY tiny fingerprints: one row types alone so the checker never solves a mega-interpolation.
    private static func fingerprint(for period: AllowancePeriodCache) -> String {
        let recordName: String = period.recordName
        let family: String = period.familyRecordName
        let profile: String = period.profileRecordName
        let week = String(Int(period.weekOf.timeIntervalSince1970))
        let status: String = period.status
        let earned = String(period.totalEarned)
        let completed = String(period.questsCompleted)
        let total = String(period.questsTotal)
        let paidAmountValue: Int64 = period.paidAmount ?? -1
        let paidAmount = String(paidAmountValue)
        let paidDateValue: Int = if let paidDate = period.paidDate {
            Int(paidDate.timeIntervalSince1970)
        } else {
            -1
        }
        let paidDate = String(paidDateValue)
        let fields: [String] = [recordName, family, profile, week, status, earned, completed, total, paidAmount, paidDate]
        return join(fields)
    }

    /// WHY tiny fingerprints: one row types alone so the checker never solves a mega-interpolation.
    private static func fingerprint(for row: ProfileAchievementCache) -> String {
        let recordName: String = row.recordName
        let family: String = row.familyRecordName
        let profile: String = row.profileRecordName
        let achievement: String = row.achievementRecordName
        let earned = String(Int(row.earnedDate.timeIntervalSince1970))
        let fields: [String] = [recordName, family, profile, achievement, earned]
        return join(fields)
    }

    /// WHY tiny fingerprints: one row types alone so the checker never solves a mega-interpolation.
    private static func fingerprint(for achievement: AchievementCache) -> String {
        let recordName: String = achievement.recordName
        let family: String = achievement.familyRecordName
        let name: String = achievement.name
        let type: String = achievement.requirementType
        let value = String(achievement.requirementValue)
        let fields: [String] = [recordName, family, name, type, value]
        return join(fields)
    }

    /// WHY tiny fingerprints: one row types alone so the checker never solves a mega-interpolation.
    private static func fingerprint(for template: QuestTemplateCache) -> String {
        let recordName: String = template.recordName
        let family: String = template.familyRecordName
        let name: String = template.name
        let gold = String(template.goldReward)
        let xp = String(template.xpReward)
        let active = String(describing: template.isActive)
        let target = String(template.targetCount)
        let schedule: String = template.scheduleType
        let days: String = if let specificDays = template.specificDays {
            join(specificDays.sorted(), separator: ",")
        } else {
            "-"
        }
        let allOrNothing = String(describing: template.isAllOrNothing)
        let approval: String = template.approvalMode
        // WHY metrics-only: display fields never feed targets, so only scheduling fields bust.
        let fields: [String] = [recordName, family, name, gold, xp, active, target, schedule, days, allOrNothing, approval]
        return join(fields)
    }

    /// WHY tiny fingerprints: one row types alone so the checker never solves a mega-interpolation.
    private static func fingerprint(familyContext: DashboardMetricsCalculator.FamilyContext, freshnessVersion: Int) -> String {
        let family: String = familyContext.recordName ?? "-"
        let day: String = familyContext.payoutDay.rawValue
        let policy: String = familyContext.payoutPolicy?.rawValue ?? "-"
        let freshness = String(freshnessVersion)
        let fields: [String] = [family, day, policy, freshness]
        return join(fields, separator: ",")
    }

    /// WHY live-check: memo holds live @Model rows, so deleted rows bust instead of re-faulting.
    private static func isMemoLive(_ metrics: DashboardMetricsCalculator.Metrics) -> Bool {
        let heroesLive: Bool = metrics.weekSummary?.heroSummaries.allSatisfy { !$0.profile.isDeleted } ?? true
        let cardsLive: Bool = metrics.childAccountCards.allSatisfy { !$0.profile.isDeleted }
        let payoutsLive: Bool = metrics.pastPayouts.allSatisfy { !$0.isDeleted }
        return heroesLive && cardsLive && payoutsLive
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
        guard syncSubscriptionID == nil else { return }
        let (stream, id) = coordinator.subscribe()
        syncSubscriptionID = id
        syncTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                // WHY hop: stream resumes off isolation, so awaiting re-enters MainActor before touching view state.
                switch event {
                case .recordChanged:
                    self.handleRecordChangedSync()
                case .shareAccepted, .zoneReset:
                    await self.refresh()
                }
            }
        }
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
        invalidateMemo()
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
