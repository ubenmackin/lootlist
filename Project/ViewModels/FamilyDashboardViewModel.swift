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

    /// `CKShare` participants shown in the Invitations panel in Guild Settings.
    /// Active member Profiles are excluded (they're owned by `heroes` /
    /// `parents`); the rows are pending invites, departed members whose
    /// identity still holds share access, and recently revoked (`.removed`)
    /// identities.
    private(set) var invitations: [FamilyInvitation] = []

    private(set) var weekSummary: WeekendSummary?

    private(set) var pastPayouts: [AllowancePeriodCache] = []

    private(set) var isLoading: Bool = false

    private(set) var isLoadingPayouts: Bool = false

    var loadError: String?

    private let questService: QuestService
    private let treasury: TreasuryService
    private let achievements: AchievementService
    private let familyService: FamilyProfileFetching
    private let appState: AppState
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "FamilyDashboard")

    /// Mirrors `TreasuryService.toastManager` so async breakdown fetches can
    /// surface `GoldCalculation.totalCredit` throw failures with a retry toast
    /// rather than silently hanging the wallet. Wired by the view via
    /// `AppDependencies` when available; nil in unit-test inits where the view
    /// layer provides the toast.
    var toastManager: ToastManager? {
        treasury.toastManager
    }

    /// Stable, non-PII row token cache. Each unique identity key is mapped to
    /// a deterministic SHA256 token on first encounter and reused on
    /// subsequent calls so SwiftUI row identity stays stable across refreshes.
    private static var identityTokenCache: [String: String] = [:]

    /// Per-refresh counter for assigning sequential numeric labels to
    /// identities. Reset at the start of each `refreshInvitations()` call so
    /// labels stay stable within a single pass regardless of how many
    /// identities are present.
    private var identityLabelCounter: [String: Int] = [:]

    private var syncSubscriptionID: UUID?
    private var syncTask: Task<Void, Never>?

    /// Long-lived observer for `FamilyShareReconciler`'s roster-changed
    /// notification. The reconciler posts it after a successful reconcile pass
    /// that mutated the membership layer; the view model responds by re-running
    /// `refreshInvitations()` so the parent's Invitations panel drops the
    /// matching row the moment the local cache and the share-side participant
    /// list converge. The task is held for the lifetime of the view model;
    /// it terminates naturally via the `[weak self]` guard when the view
    /// model is deallocated (the next notification after deallocation
    /// unwinds the `for await` loop).
    private var rosterObserverTask: Task<Void, Never>?

    init(questService: QuestService,
         treasury: TreasuryService,
         achievementService: AchievementService,
         familyService: FamilyProfileFetching,
         appState: AppState)
    {
        self.questService = questService
        self.treasury = treasury
        achievements = achievementService
        self.familyService = familyService
        self.appState = appState

        // Re-trigger invitation classification on roster mutations: SwiftData
        // writes the new `ProfileCache` to the cache (which fires the view's
        // `.onChange(of: cachedProfiles)` → `rebuildLists`), but the Invitations
        // panel is sourced from the CKShare participant list, not the cache.
        // Without this hook the panel would only refresh on a manual pull or
        // the next `.syncDidComplete` cycle. The reconciler's post is the
        // canonical signal that the share-side participant list has converged
        // with the local cache.
        rosterObserverTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .familyRosterChanged) {
                guard let self else { return }
                await self.refreshInvitations()
            }
        }
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
            do {
                try await achievements.seedDefaultAchievements(family: family)
            } catch {
                logger.debug("Default achievements seed skipped: \(error, privacy: .private)")
            }
        }
    }

    /// Resolves the family's `CKShare` for the given invite role, fetching the
    /// existing share or creating a new one. Returns nil when the current user
    /// is not the zone owner or the share cannot be resolved.
    func prepareInviteShare(for role: UserRole) async -> CKShare? {
        guard appState.isZoneOwner,
              appState.familyZoneID != nil,
              let family = appState.family
        else { return nil }
        let cloudKit = questService.cloudKitReference
        do {
            return try await cloudKit.fetchOrCreateShare(for: family.id, role: role)
        } catch {
            logger.error("Failed to fetch or create invitation share: \(error, privacy: .private)")
            return nil
        }
    }

    /// Reloads the Invitations panel from the family's `CKShare` participant
    /// records. Classification is driven by `fetchShareParticipantStatuses`
    /// (identity + acceptance status, testable without fabricated
    /// `CKShare.Participant` objects) and the participant objects provide
    /// revocation handles. Rows are classified
    /// three ways: active member Profiles are skipped (shown in `heroes` /
    /// `parents`); deactivated member Profiles whose identity is still an
    /// accepted participant are flagged as departed members so the Guild Master
    /// can revoke their lingering share access; recently revoked (`.removed`)
    /// identities surface read-only while CloudKit propagates the removal.
    /// Pending invites that have not yet established an iCloud identity
    /// (email/phone only) have no status entry and are rendered from the
    /// participant objects directly. Their display labels are always redacted.
    /// The share owner's own participant entry —
    /// the signed-in user's identity — is never rendered as a revocable row.
    func refreshInvitations() async {
        guard appState.isZoneOwner, let family = appState.family else {
            invitations = []
            return
        }
        let cloudKit = questService.cloudKitReference
        var currentUserRecordName: String
        do {
            // Resolve the signed-in user's identity before classifying rows:
            // the share owner's participant entry is that identity, and it must
            // never surface as a revocable row (revoking it would strip the
            // current user's own zone access). Resolution failure is
            // fail-closed — the panel loads nothing rather than risk offering a
            // revoke button on the user's own access.
            let currentUserRecordID = try await cloudKit.currentUserRecordID()
            currentUserRecordName = currentUserRecordID.recordName
        } catch {
            logger.warning("Failed to resolve current user record ID for invitation refresh: \(error, privacy: .private)")
            invitations = []
            return
        }

        let activeRecordNames = Set((heroes + parents).map(\.iCloudUserRecordName))
        // Deactivated member profiles: their identity can remain an
        // accepted share participant (a self-leave cannot revoke a share it
        // does not own), which is why the panel flags them for owner-side
        // revocation instead of hiding them.
        let inactiveIdentities = await departedMemberIdentities(for: family)

        let participants: [CKShare.Participant]
        do {
            participants = try await cloudKit.fetchShareParticipants(for: family.id)
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
            statuses = try await cloudKit.fetchShareParticipantStatuses(for: family.id)
        } catch {
            logger.error("Failed to load share participant statuses: \(error, privacy: .private)")
            invitations = []
            return
        }
        let roleMap: [String: UserRole]
        do {
            roleMap = try await cloudKit.fetchShareParticipantRoles(for: family.id)
        } catch {
            logger.warning("Failed to fetch share participant roles: \(error, privacy: .private)")
            roleMap = [:]
        }

        var result: [FamilyInvitation] = []
        var handledRecordNames = Set<String>()
        var handledKeys = Set<String>()

        // Pre-compute a stable numeric label for every status-based identity.
        // Sorted by identity key so the same set of identities always receives
        // the same sequential numbers, regardless of processing order.
        identityLabelCounter = [:]
        var labelIndex = 0
        for status in statuses.sorted(by: { ($0.identityKey ?? "") < ($1.identityKey ?? "") }) {
            if let key = status.identityKey {
                identityLabelCounter[key] = labelIndex
                labelIndex += 1
            }
        }

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

        invitations = result
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
                id: Self.opaqueIdentityToken(key),
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
                id: Self.opaqueIdentityToken(key),
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
                id: Self.opaqueIdentityToken(key),
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
            id: Self.invitationID(for: participant),
            identity: participantIdentityDisplay(participant),
            statusText: isRemoved ? "Removed" : Self.invitationStatusText(participant.acceptanceStatus),
            participant: participant,
            identityRecordName: recordName,
            kind: isRemoved ? .removedIdentity : .pendingInvite,
            targetRole: targetRole
        )
    }

    /// Maps each deactivated member's identity record name to their display
    /// name for the Invitations panel. Best-effort: when the profile query
    /// fails the map is empty and departed members degrade to plain invitation
    /// rows rather than blocking the panel.
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

    /// Revokes a pending invitation or a departed member's lingering share access
    /// by removing the participant from the family shares (owner-side access
    /// layer only — pending invites have no `Profile` to deactivate, and
    /// departed members' `Profile`s are already inactive). Uses the matched
    /// participant object when present (covers pending invites without an
    /// iCloud record name), else falls back to revocation by record name.
    func revokeInvitation(_ invitation: FamilyInvitation) async {
        guard appState.isZoneOwner, let family = appState.family else { return }
        let cloudKit = questService.cloudKitReference
        // Defense in depth: classification never yields a revocable row for the
        // share owner or the signed-in user, but refuse anyway if a stale row
        // slips through — revoking either would strip the current user's own
        // zone access. `.removed` identities are read-only by construction:
        // CloudKit keeps the identity visible only while propagation finishes,
        // so there is nothing left to revoke.
        if invitation.kind == .removedIdentity {
            return
        }
        if invitation.participant?.role == .owner {
            return
        }
        if let identityRecordName = invitation.identityRecordName {
            do {
                let currentUserRecordID = try await cloudKit.currentUserRecordID()
                if identityRecordName == currentUserRecordID.recordName {
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
                try await cloudKit.removeParticipant(participant, from: family.id)
            } else if let identityRecordName = invitation.identityRecordName {
                try await cloudKit.removeParticipant(iCloudUserRecordName: identityRecordName, from: family.id)
            } else {
                logger.error("Failed to revoke invitation: no participant identity to revoke")
                return
            }
            invitations.removeAll { $0.id == invitation.id }
        } catch {
            logger.error("Failed to revoke invitation: \(error, privacy: .private)")
            // The revocation must never be a silent no-op: when the service
            // cannot match the participant in any role share it throws, and
            // that failure is surfaced to the Invitations panel so the caller
            // knows access was not actually revoked.
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func invitationID(for participant: CKShare.Participant) -> String {
        // Row identifiers must never embed the raw identity (iCloud record
        // name, email, or phone number): they surface in accessibility
        // identifiers and UI-test queries. Hash the identity key instead so
        // the token stays stable across refreshes while leaking nothing.
        // Fallback ordering mirrors `ShareParticipantKey`: record name → email
        // → phone → server-assigned `participantID`, then the
        // `ObjectIdentifier` key as a last resort.
        if let key = ShareParticipantKey.key(for: participant) {
            return opaqueIdentityToken(key)
        }
        return opaqueIdentityToken("object:\(ObjectIdentifier(participant))")
    }

    /// Stable, non-PII row token for the Invitations panel. The raw CloudKit
    /// identity (iCloud record name, email, or phone number) must never appear
    /// in a `FamilyInvitation` identifier — those identifiers back SwiftUI row
    /// identity and surface in accessibility identifiers / UI-test queries.
    /// SHA256 produces a deterministic, collision-resistant token without an
    /// embedded secret, preserving stable row identity across refreshes while
    /// preventing raw identity leakage.
    private static func opaqueIdentityToken(_ value: String) -> String {
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

    /// Produces a stable display label without exposing the participant's
    /// record name, email address, phone number, or display name. When a
    /// counter is available, labels are sequential ("Guild Member 1", etc.)
    /// so different identities are visually distinguishable without leaking
    /// any identity-derived information.
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

    /// Async week-summary refresh that exercises the throwing wallet path.
    /// `TreasuryService.weeklyBreakdown` throws on `GoldCalculation.totalCredit`
    /// fetch failures; this `do/catch` boundary surfaces the failure via
    /// `loadError` + `ToastManager` + retry instead of hanging the dashboard.
    /// The cache-first `rebuildLists` below intentionally stays `sync`/`non-throwing`
    /// (see its doc); this async path is for callers that need authoritative
    /// CloudKit-backed totals (e.g. pull-to-refresh, post-payout re-query).
    func refreshWeekSummary() async {
        guard let family = appState.family else { return }
        let heroesForBreakdown = heroes
        guard !heroesForBreakdown.isEmpty else { return }
        isLoadingPayouts = true
        defer { isLoadingPayouts = false }
        for hero in heroesForBreakdown {
            let profile = resolveProfile(for: hero, family: family)
            do {
                _ = try await treasury.weeklyBreakdown(profile: profile, family: family, weekOf: Date())
                if loadError != nil {
                    loadError = nil
                }
            } catch {
                logger.warning("Failed to load week summary for \(hero.recordName, privacy: .private): \(error, privacy: .private)")
                loadError = "Could not load wallet totals. Pull to retry."
                toastManager?.show(message: loadError ?? "Could not load wallet totals. Pull to retry.", type: .warning)
                // Do not clear `weekSummary` — preserve last successful totals so UI doesn't hang empty.
                break
            }
        }
    }

    private func resolveProfile(for cache: ProfileCache, family: Family) -> Profile {
        cache.toProfile(zoneID: family.id.zoneID)
    }

    /// Cache-first, synchronous rebuild from SwiftData `@Query` rows. This path
    /// intentionally **does not throw** and does not call
    /// `TreasuryService.weeklyBreakdown` / `GoldCalculation.totalCredit`.
    /// It derives gold via `GoldCalculation.netWeeklyGold` (pure cache math)
    /// so the dashboard hydrates instantly offline and never hangs on a network
    /// failure. Throwing CloudKit work belongs in `refreshWeekSummary()` above,
    /// which callers invoke with `do/catch` + toast + retry.
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
                    Calendar.iso8601UTC.isDate($0.weekOf, inSameDayAs: heroWeekOf)
            }
            let isPeriodPaid = heroPeriod?.statusEnum == .paid

            let earned: Double
            if isPeriodPaid {
                earned = 0.0
            } else {
                let goldFromQuests = GoldCalculation.netWeeklyGold(
                    quests: quests,
                    logs: logs,
                    profileRecordName: hero.recordName,
                    payoutPolicy: hero.payoutPolicyEnum,
                    weekRange: heroWeekRange
                )

                let heroLedgers = ledgers.filter {
                    $0.profileRecordName == hero.recordName && heroWeekRange.contains($0.date)
                }
                let bonusGold = heroLedgers
                    .filter { $0.amount > 0 && $0.source != "quest" }
                    .reduce(0.0) { $0 + $1.amount }
                earned = goldFromQuests + bonusGold
            }

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
    }

    func reset() {
        heroes = []
        parents = []
        weekSummary = nil
        pastPayouts = []
        loadError = nil
        isLoading = false
        isLoadingPayouts = false
    }
}

struct WeekendSummary: Equatable {
    let weekOf: Date

    let totalEarned: Double

    /// Amount pending payout for non-real-time heroes only.
    /// Real-time heroes' weekly gold is disbursed immediately on
    /// each quest completion, so it is never "pending" a weekly batch.
    var pendingPayoutAmount: Double {
        heroSummaries.reduce(into: 0.0) { acc, hero in
            if hero.profile.payoutPolicyEnum != .realTime {
                acc += hero.weeklyGoldEarned
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

    let weeklyGoldEarned: Double

    let currentStreak: Int

    let trophiesEarned: Int

    var avatarRenderSpec: AvatarRenderSpec?
}

/// A `CKShare` participant (or participant-derived identity) shown in the Guild
/// Settings Invitations panel: with a stable redacted display label, a CloudKit
/// acceptance status, a `kind` that drives presentation and availability of the
/// revocation action, and identity fields for the revocation call itself —
/// `participant` when an object is available, else `identityRecordName`. `id`
/// is a stable opaque token derived from the identity (never the raw iCloud
/// record name, email, or phone number) — it backs SwiftUI row identity and
/// accessibility identifiers only, so no contact data leaks into UI tests.
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
    /// A member whose `Profile` was deactivated (left the guild) but whose
    /// identity still holds shared-zone access — e.g. after a hero self-leave,
    /// since a non-owner device cannot revoke a share it does not own. The
    /// Guild Master revokes here to close the access-layer gap.
    case departedMember
    /// An identity the Guild Master already revoked; CloudKit keeps it visible
    /// on the share with `.removed` status until propagation completes.
    /// Read-only row.
    case removedIdentity
}
