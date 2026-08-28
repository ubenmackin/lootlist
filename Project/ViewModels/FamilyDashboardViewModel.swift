//
//  FamilyDashboardViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import CryptoKit
import Foundation
import Observation
import os

/// Duplicated from `FamilyShareReconciler` (file-private) — the view model
/// is the canonical subscriber for roster-change notifications.
private extension Notification.Name {
    static let familyRosterChanged = Notification.Name("familyRosterChanged")
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

    /// Stable, non-PII row token cache. Each unique identity key is mapped to
    /// a deterministic SHA256 token on first encounter and reused on
    /// subsequent calls so SwiftUI row identity stays stable across refreshes.
    private var identityTokenCache: [String: String] = [:]

    /// Counter for sequential anonymous labels in the Invitations panel.
    private var identityLabelCounter: [String: Int] = [:]

    private var syncSubscriptionID: UUID?
    private var syncTask: Task<Void, Never>?

    /// Observer for roster changes to refresh invitations when membership updates.
    private var rosterObserverTask: Task<Void, Never>?

    init(questService: QuestService,
         treasury: TreasuryService,
         achievementService: AchievementService,
         familyService: any FamilyProfileFetching,
         appState: AppState)
    {
        self.questService = questService
        self.treasury = treasury
        achievements = achievementService
        self.familyService = familyService
        self.appState = appState
    }

    /// Observes roster changes to refresh invitations when members join or leave.
    func startRosterObserver() {
        guard rosterObserverTask == nil else { return }
        rosterObserverTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .familyRosterChanged) {
                guard let self else { return }
                await self.refreshInvitations()
            }
        }
    }

    /// Stops the roster-change observer started by `startRosterObserver()`.
    func stopRosterObserver() {
        rosterObserverTask?.cancel()
        rosterObserverTask = nil
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

    /// Resolves role-specific CKShare via FamilyService (zone owner only).
    func prepareInviteShare(for role: UserRole) async -> CKShare? {
        guard appState.isZoneOwner,
              appState.familyZoneID != nil,
              let family = appState.family
        else { return nil }
        do {
            return try await familyService.prepareInviteShare(for: family, role: role)
        } catch {
            logger.error("Failed to fetch or create invitation share: \(error, privacy: .private)")
            return nil
        }
    }

    /// Reloads and classifies invitation statuses from the family's `CKShare`
    /// participants. All CloudKit interaction is routed through `FamilyService`
    /// so the ViewModel never holds a raw CloudKit reference.
    func refreshInvitations() async {
        guard appState.isZoneOwner, let family = appState.family else {
            invitations = []
            return
        }
        var currentUserRecordName: String
        do {
            // Resolve signed-in user identity to prevent rendering self as revocable row.
            currentUserRecordName = try await familyService.currentUserRecordName()
        } catch {
            logger.warning("Failed to resolve current user record ID for invitation refresh: \(error, privacy: .private)")
            invitations = []
            return
        }

        var activeRecordNames = Set((heroes + parents).map(\.iCloudUserRecordName))
        // Surfaces deactivated members retaining share access for owner revocation.
        let inactiveIdentities = await departedMemberIdentities(for: family)

        let participants: [CKShare.Participant]
        do {
            participants = try await familyService.fetchShareParticipants(for: family)
        } catch {
            logger.error("Failed to load share participants: \(error, privacy: .private)")
            invitations = []
            return
        }
        let participantByRecordName = Dictionary(
            participants.compactMap { participant -> (String, CKShare.Participant)? in
                guard let recordName = participant.userIdentity.userRecordID?.recordName else { return nil }
                return (recordName, participant)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let statuses: [ShareParticipantStatus]
        do {
            statuses = try await familyService.fetchShareParticipantStatuses(for: family)
        } catch {
            logger.error("Failed to load share participant statuses: \(error, privacy: .private)")
            invitations = []
            return
        }

        let roleMap: [String: UserRole]
        do {
            roleMap = try await familyService.fetchShareParticipantRoles(for: family)
        } catch {
            logger.warning("Failed to fetch share participant roles: \(error, privacy: .private)")
            roleMap = [:]
        }

        await reconcileMissingAcceptedMembers(
            for: family,
            statuses: statuses,
            currentUserRecordName: currentUserRecordName,
            activeRecordNames: &activeRecordNames
        )

        computeIdentityLabels(from: statuses)

        invitations = assembleInvitations(
            statuses: statuses,
            participants: participants,
            currentUserRecordName: currentUserRecordName,
            activeRecordNames: activeRecordNames,
            inactiveIdentities: inactiveIdentities,
            participantByRecordName: participantByRecordName,
            roleMap: roleMap
        )
    }

    private func reconcileMissingAcceptedMembers(
        for family: Family,
        statuses: [ShareParticipantStatus],
        currentUserRecordName: String,
        activeRecordNames: inout Set<String>
    ) async {
        let missingAcceptedMembers = statuses.contains { status in
            guard let recordName = status.recordName,
                  !status.isRemoved,
                  recordName != currentUserRecordName else { return false }
            return !activeRecordNames.contains(recordName)
        }

        guard missingAcceptedMembers else { return }

        await familyService.refreshProfilesFromCloudKit(for: family)
        do {
            let fresh = try await familyService.fetchAllProfilesForFamily(family)
            let freshActive = fresh.filter(\.isActive)
            activeRecordNames.formUnion(Set(freshActive.map(\.iCloudUserID.recordName)))
        } catch {
            logger.warning("FamilyDashboard roster reconciliation skipped: \(error, privacy: .private)")
        }
    }

    private func computeIdentityLabels(from statuses: [ShareParticipantStatus]) {
        identityLabelCounter = [:]
        var labelIndex = 0
        for status in statuses.sorted(by: { ($0.identityKey ?? "") < ($1.identityKey ?? "") }) {
            if let key = status.identityKey {
                identityLabelCounter[key] = labelIndex
                labelIndex += 1
            }
        }
    }

    private func assembleInvitations(
        statuses: [ShareParticipantStatus],
        participants: [CKShare.Participant],
        currentUserRecordName: String,
        activeRecordNames: Set<String>,
        inactiveIdentities: [String: String],
        participantByRecordName: [String: CKShare.Participant],
        roleMap: [String: UserRole]
    ) -> [FamilyInvitation] {
        var result: [FamilyInvitation] = []
        var handledRecordNames = Set<String>()
        var handledKeys = Set<String>()

        // Statuses are the authoritative identity view (they include
        // `.removed` markers that object-only reading has to filter).
        for status in statuses {
            let key = status.identityKey ?? status.recordName.map { "record:\($0)" }
            guard let key else { continue }
            handledKeys.insert(key)
            if let recordName = status.recordName {
                handledRecordNames.insert(recordName)
            }
            if let invitation = buildStatusInvitation(
                status: status,
                currentUserRecordName: currentUserRecordName,
                activeRecordNames: activeRecordNames,
                inactiveIdentities: inactiveIdentities,
                participantByRecordName: participantByRecordName,
                roleMap: roleMap
            ) {
                result.append(invitation)
            }
        }

        // Pending invites without an established iCloud identity have no
        // status entry; render them from the participant objects.
        for participant in participants {
            if let invitation = buildParticipantInvitation(
                participant: participant,
                currentUserRecordName: currentUserRecordName,
                handledRecordNames: handledRecordNames,
                handledKeys: handledKeys,
                roleMap: roleMap
            ) {
                result.append(invitation)
            }
        }

        return result
    }

    private func buildStatusInvitation(
        status: ShareParticipantStatus,
        currentUserRecordName: String,
        activeRecordNames: Set<String>,
        inactiveIdentities: [String: String],
        participantByRecordName: [String: CKShare.Participant],
        roleMap: [String: UserRole]
    ) -> FamilyInvitation? {
        let key = status.identityKey ?? status.recordName.map { "record:\($0)" }
        guard let key else { return nil }
        let participant = status.recordName.flatMap { participantByRecordName[$0] }
        let targetRole = status.recordName.flatMap { roleMap[$0] } ?? roleMap[key]

        if participant?.role == .owner || status.recordName == currentUserRecordName {
            return nil
        }
        if let recordName = status.recordName, activeRecordNames.contains(recordName) {
            return nil
        }
        if status.isRemoved {
            return FamilyInvitation(
                id: opaqueIdentityToken(key),
                identity: identityDisplay(for: key, recordName: status.recordName, participant: participant),
                statusText: "Removed",
                participant: participant,
                identityRecordName: status.recordName,
                kind: .removedIdentity,
                targetRole: targetRole
            )
        }
        if let recordName = status.recordName, let displayName = inactiveIdentities[recordName] {
            return FamilyInvitation(
                id: opaqueIdentityToken(key),
                identity: displayName,
                statusText: "Left the guild — revoke share access",
                participant: participant,
                identityRecordName: recordName,
                kind: .departedMember,
                targetRole: targetRole
            )
        }
        if let recordName = status.recordName {
            return FamilyInvitation(
                id: opaqueIdentityToken(key),
                identity: identityDisplay(for: key, recordName: recordName, participant: participant),
                statusText: "Accepted",
                participant: participant,
                identityRecordName: recordName,
                kind: .pendingInvite,
                targetRole: targetRole
            )
        }
        return nil
    }

    private func buildParticipantInvitation(
        participant: CKShare.Participant,
        currentUserRecordName: String,
        handledRecordNames: Set<String>,
        handledKeys: Set<String>,
        roleMap: [String: UserRole]
    ) -> FamilyInvitation? {
        let recordName = participant.userIdentity.userRecordID?.recordName
        if participant.role == .owner || (recordName != nil && recordName == currentUserRecordName) {
            return nil
        }
        if let recordName, handledRecordNames.contains(recordName) {
            return nil
        }
        let pKey = ShareParticipantKey.key(for: participant)
        if let pKey, handledKeys.contains(pKey) {
            return nil
        }
        let targetRole = recordName.flatMap { roleMap[$0] } ?? pKey.flatMap { roleMap[$0] }
        let isRemoved = participant.acceptanceStatus == .removed
        return FamilyInvitation(
            id: invitationID(for: participant),
            identity: participantIdentityDisplay(participant),
            statusText: isRemoved ? "Removed" : Self.invitationStatusText(participant.acceptanceStatus),
            participant: participant,
            identityRecordName: recordName,
            kind: isRemoved ? .removedIdentity : .pendingInvite,
            targetRole: targetRole
        )
    }

    /// Maps deactivated member identity record names to display names (best-effort).
    private func departedMemberIdentities(for family: Family) async -> [String: String] {
        let profiles: [Profile]
        do {
            profiles = try await familyService.fetchAllProfilesForFamily(family)
        } catch {
            logger.warning("Failed to fetch all profiles for family: \(error, privacy: .private)")
            return [:]
        }
        var identities: [String: String] = [:]
        for profile in profiles where !profile.isActive && !profile.iCloudUserID.recordName.isEmpty {
            identities[profile.iCloudUserID.recordName] = profile.displayName
        }
        return identities
    }

    /// Returns a stable, redacted label for a status-driven row. CloudKit
    /// record names and contact lookup values are retained only in the
    /// revocation fields, never in the value rendered by the dashboard.
    private func identityDisplay(for key: String, recordName: String?, participant: CKShare.Participant?) -> String {
        if let participant {
            return participantIdentityDisplay(participant)
        }
        let identityKey = recordName.map { "record:\($0)" } ?? key
        return Self.redactedIdentityLabel(for: identityKey, counter: identityLabelCounter)
    }

    /// Revokes a pending invitation or departed member's share access.
    /// CloudKit interaction is routed through `FamilyService` so the ViewModel
    /// never holds a raw CloudKit reference.
    func revokeInvitation(_ invitation: FamilyInvitation) async {
        guard appState.isZoneOwner, let family = appState.family else { return }
        // Guard against revoking owner, self, or already-removed identities.
        if invitation.kind == .removedIdentity {
            return
        }
        if invitation.participant?.role == .owner {
            return
        }
        if let identityRecordName = invitation.identityRecordName {
            do {
                let currentUserRecordName = try await familyService.currentUserRecordName()
                if identityRecordName == currentUserRecordName {
                    logger.error("Refusing to revoke the current user's own share access")
                    return
                }
            } catch {
                logger.warning("Failed to resolve current user record ID for revocation guard: \(error, privacy: .private)")
                return
            }
        }

        do {
            if let participant = invitation.participant {
                try await familyService.revokeInvitation(participant: participant, from: family)
            } else if let identityRecordName = invitation.identityRecordName {
                try await familyService.revokeInvitation(identityRecordName: identityRecordName, from: family)
            } else {
                logger.error("Failed to revoke invitation: no participant identity to revoke")
                return
            }
            invitations.removeAll { $0.id == invitation.id }
        } catch {
            logger.error("Failed to revoke invitation: \(error, privacy: .private)")
            // Revocation failures are surfaced to the UI.
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func invitationID(for participant: CKShare.Participant) -> String {
        // Hash identity key to create stable, non-PII row tokens.
        if let key = ShareParticipantKey.key(for: participant) {
            return opaqueIdentityToken(key)
        }
        return opaqueIdentityToken("object:\(ObjectIdentifier(participant))")
    }

    /// Generates a stable, non-PII SHA256 token for row identification.
    private func opaqueIdentityToken(_ value: String) -> String {
        if let cached = identityTokenCache[value] {
            return cached
        }
        let digest = SHA256.hash(data: Data(value.utf8))
        let result = digest.map { String(format: "%02x", $0) }.joined()
        identityTokenCache[value] = result
        return result
    }

    private func participantIdentityDisplay(_ participant: CKShare.Participant) -> String {
        guard let key = ShareParticipantKey.key(for: participant) else {
            return "Invited member"
        }
        return Self.redactedIdentityLabel(for: key, counter: identityLabelCounter)
    }

    /// Produces a redacted, distinguishable display label without leaking contact data.
    private static func redactedIdentityLabel(for identityKey: String, counter: [String: Int] = [:]) -> String {
        if let number = counter[identityKey] {
            return "Guild Member \(number + 1)"
        }
        return "Guild Member"
    }

    private static func invitationStatusText(_ status: CKShare.ParticipantAcceptanceStatus) -> String {
        switch status {
        case .pending: "Invited"
        case .accepted: "Accepted"
        case .removed: "Removed"
        case .unknown: "Pending"
        @unknown default: "Invited"
        }
    }

    /// Synchronous rebuild from SwiftData `@Query` rows using pure cache math.
    func rebuildLists(
        profiles: [ProfileCache],
        quests: [QuestCache],
        logs: [QuestCompletionCache],
        ledgers: [LedgerEntryCache],
        allowancePeriods: [AllowancePeriodCache],
        profileAchievements: [ProfileAchievementCache],
        achievements _: [AchievementCache]
    ) {
        let familyName = appState.family?.id.recordName

        let familyPayoutDay = appState.family?.payoutDay ?? .sunday
        let active = profiles.filter(\.isActive)
        let computedHeroes = active
            .filter { $0.roleEnum == .hero }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let computedParents = active
            .filter { $0.roleEnum?.isParent == true }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        var heroSummaries: [HeroSummary] = []
        heroSummaries.reserveCapacity(computedHeroes.count)

        for hero in computedHeroes {
            let heroPayoutDay = hero.payoutDayEnum ?? familyPayoutDay
            let heroWeekOf = WeekMath.startOfWeek(for: Date(), payoutDay: heroPayoutDay)
            let heroWeekRange = WeekMath.weekRange(starting: heroWeekOf)

            let heroQuests = quests.filter { $0.assigneeRecordName == hero.recordName && heroWeekRange.contains($0.weekOf) }
            let heroLogs = logs.filter { $0.completerRecordName == hero.recordName && (heroWeekRange.contains($0.weekOf) || heroWeekRange.contains($0.completedDate)) }

            let approvedLogs = heroLogs.filter {
                $0.verificationStatusEnum == .autoApproved || $0.verificationStatusEnum == .verified
            }

            let fullyCompletedQuestsCount = heroQuests.filter { quest in
                let qApprovedLogs = approvedLogs.filter { $0.questRecordName == quest.recordName }
                return GoldCalculation.isFullyCompleted(quest: quest, approvedCount: qApprovedLogs.count)
            }.count

            let heroPeriod = allowancePeriods.first {
                $0.profileRecordName == hero.recordName &&
                    WeekMath.startOfWeek(for: $0.weekOf, payoutDay: heroPayoutDay) == heroWeekOf
            }
            let isPeriodPaid = heroPeriod?.statusEnum == .paid

            let questGold: Double
            let bonusGold: Double
            if isPeriodPaid {
                questGold = 0.0
                bonusGold = 0.0
            } else {
                let effectivePolicy = hero.payoutPolicyEnum ?? appState.family?.payoutPolicy ?? .perQuest
                questGold = GoldCalculation.netWeeklyGold(
                    quests: quests,
                    logs: logs,
                    profileRecordName: hero.recordName,
                    payoutPolicy: effectivePolicy,
                    weekRange: heroWeekRange
                )

                let heroLedgers = ledgers.filter {
                    $0.profileRecordName == hero.recordName && heroWeekRange.contains($0.date)
                }
                bonusGold = heroLedgers
                    .filter { $0.amount > 0 && $0.source != "quest" }
                    .reduce(0.0) { $0 + $1.amount }
            }
            let earned = questGold + bonusGold

            let streakLogs = logs.filter { $0.completerRecordName == hero.recordName }
            let streak = StreakCalculator.computeStreak(from: streakLogs)
            let trophies = profileAchievements
                .filter { $0.profileRecordName == hero.recordName }
                .count

            heroSummaries.append(HeroSummary(
                profile: hero,
                weeklyQuestsCompleted: fullyCompletedQuestsCount,
                weeklyQuestsTotal: heroQuests.count,
                weeklyGoldEarned: earned,
                weeklyQuestGold: questGold,
                currentStreak: streak,
                trophiesEarned: trophies
            ))
        }

        let totalEarned = heroSummaries.reduce(into: 0.0) { $0 += $1.weeklyGoldEarned }
        let totalQuests = heroSummaries.reduce(into: 0) { $0 += $1.weeklyQuestsCompleted }
        let computedWeekSummary = WeekendSummary(
            weekOf: WeekMath.startOfWeek(for: Date(), payoutDay: familyPayoutDay),
            totalEarned: totalEarned,
            totalQuestsCompleted: totalQuests,
            heroSummaries: heroSummaries
        )

        let computedPastPayouts = allowancePeriods
            .filter { familyName == nil || $0.familyRecordName == familyName }
            .sorted { $0.weekOf > $1.weekOf }

        // Dashboard card computations — derived from the same cached rows
        // the rest of rebuildLists already processes, so no extra query.
        let heroRecordNames = Set(computedHeroes.map(\.recordName))
        let heroLedgerEntries = ledgers.filter { heroRecordNames.contains($0.profileRecordName) }
        familyOutflow = heroLedgerEntries.reduce(0.0) { $0 + $1.amount }

        let pendingLogs = logs.filter { $0.verificationStatusEnum == .pending }
        pendingReviewCount = pendingLogs.count

        childAccountCards = computedHeroes.map { hero in
            let heroBalance = heroLedgerEntries
                .filter { $0.profileRecordName == hero.recordName }
                .reduce(0.0) { $0 + $1.amount }
            let heroPending = pendingLogs
                .filter { $0.completerRecordName == hero.recordName }
                .count
            return ChildAccountCard(profile: hero, balance: heroBalance, pendingReviewCount: heroPending)
        }

        heroes = computedHeroes
        parents = computedParents
        weekSummary = computedWeekSummary
        pastPayouts = computedPastPayouts
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
        syncTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
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
struct FamilyInvitation: Identifiable {
    let id: String
    let identity: String
    let statusText: String
    let participant: CKShare.Participant?
    let identityRecordName: String?
    let kind: FamilyInvitationKind
    let targetRole: UserRole?

    init(
        id: String,
        identity: String,
        statusText: String,
        participant: CKShare.Participant?,
        identityRecordName: String?,
        kind: FamilyInvitationKind,
        targetRole: UserRole? = nil
    ) {
        self.id = id
        self.identity = identity
        self.statusText = statusText
        self.participant = participant
        self.identityRecordName = identityRecordName
        self.kind = kind
        self.targetRole = targetRole
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
