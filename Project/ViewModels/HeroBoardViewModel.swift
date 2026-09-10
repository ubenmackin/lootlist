//
//  HeroBoardViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation
import Observation

@MainActor
@Observable
final class HeroBoardViewModel {
    struct BoardRow: Identifiable, Equatable, Sendable {
        let quest: BoardQuestSnapshot
        let claimantName: String?
        let isClaimedByCurrentUser: Bool
        let isPending: Bool

        init(quest: BoardQuestSnapshot, claimantName: String?, isClaimedByCurrentUser: Bool, isPending: Bool = false) {
            self.quest = quest
            self.claimantName = claimantName
            self.isClaimedByCurrentUser = isClaimedByCurrentUser
            self.isPending = isPending
        }

        /// Test/legacy bridge: converts the domain snapshot to a value snapshot at the boundary so rows never hold live models.
        init(quest: Quest, claimantName: String?, isClaimedByCurrentUser: Bool, isPending: Bool = false) {
            self.init(quest: BoardQuestSnapshot(from: quest), claimantName: claimantName, isClaimedByCurrentUser: isClaimedByCurrentUser, isPending: isPending)
        }

        /// Cache bridge: snapshots the live row on isolation so rows never hold @Model references.
        init(quest: QuestCache, claimantName: String?, isClaimedByCurrentUser: Bool, isPending: Bool = false) {
            self.init(quest: BoardQuestSnapshot(from: quest), claimantName: claimantName, isClaimedByCurrentUser: isClaimedByCurrentUser, isPending: isPending)
        }

        var id: String {
            quest.recordName
        }
    }

    private(set) var availableRows: [BoardRow] = []
    private(set) var claimedRows: [BoardRow] = []
    private(set) var errorMessage: String?

    /// Record names of quests optimistically claimed on this device awaiting save confirmation.
    private var pendingClaims: Set<String> = []

    /// Record names with a claim save currently in flight on this device.
    private var inFlightClaims: Set<String> = []

    /// Record names of quests optimistically revoked on this device awaiting save confirmation.
    private var pendingRevokes: Set<String> = []

    /// Record names with a revoke save currently in flight on this device.
    private var inFlightRevokes: Set<String> = []

    private let boardService: HeroBoardService
    private let appState: AppState

    @ObservationIgnored private var viewerRow: ProfileCache?

    var isParent: Bool {
        // WHY row-first: gating must mirror @Query rows so claim/revoke never disagrees with tabs.
        if let viewerRow {
            return viewerRow.roleEnum?.isParent ?? false
        }
        return appState.currentProfile?.role.isParent ?? false
    }

    private var currentUserRecordName: String? {
        // WHY row-first: identity must mirror @Query rows so claim attribution never disagrees with gating.
        viewerRow?.recordName ?? appState.currentProfile?.id.recordName
    }

    init(boardService: HeroBoardService, appState: AppState) {
        self.boardService = boardService
        self.appState = appState
    }

    // MARK: - Load

    /// Rebuilds board rows from the SwiftData cache the view observes via
    /// `@Query`. Also settles optimistic claims: if a pending claim now shows
    /// another claimer (their server-wins ingest landed), surface the toast.
    func rebuildLists(
        quests: [QuestCache],
        profiles: [ProfileCache],
        completions _: [QuestCompletionCache] = [],
        viewerRow: ProfileCache? = nil
    ) {
        // WHY cache-first: gating mirrors queried rows so claim/revoke never disagrees with view tabs.
        // WHY completions keep board reactive: completion ingest signals quest lifecycle
        // progress, so a fresh completions pulse rebuilds rows and settles pending claims from live state.
        if let viewerRow {
            self.viewerRow = viewerRow
        }
        guard appState.family != nil else {
            availableRows = []
            claimedRows = []
            pendingClaims.removeAll()
            pendingRevokes.removeAll()
            return
        }

        let profileByName = Dictionary(uniqueKeysWithValues: profiles.map { ($0.recordName, $0) })
        let currentUser = currentUserRecordName
        // WHY optimistic rows stay visible while the claim save confirms.
        let pending = pendingRecordNames()

        // WHY snapshots: rows hold value copies snapshotted on isolation; domain conversion happens only at claim/revoke.
        let rows: [BoardRow] = quests.compactMap { cached in
            guard cached.isActive, HeroBoardService.isBoardQuest(cached) else { return nil }
            let claimer = cached.claimedByProfileRecordName
            return BoardRow(
                quest: cached,
                claimantName: claimer.flatMap { profileByName[$0]?.displayName },
                isClaimedByCurrentUser: claimer == currentUser,
                isPending: pending.contains(cached.recordName)
            )
        }
        .sorted { $0.quest.questName.localizedCaseInsensitiveCompare($1.quest.questName) == .orderedAscending }

        availableRows = rows.filter { $0.quest.claimedByProfileRecordName == nil }
        claimedRows = rows.filter { $0.quest.claimedByProfileRecordName != nil }

        settlePendingClaims()
        settlePendingRevokes()
        refreshPendingFlags()
    }

    /// WHY one union: claim and revoke pending share badge and disable state.
    private func pendingRecordNames() -> Set<String> {
        pendingClaims.union(inFlightClaims).union(pendingRevokes).union(inFlightRevokes)
    }

    /// WHY settled rows must clear pending so the badge tracks live state.
    private func refreshPendingFlags() {
        let pending = pendingRecordNames()
        availableRows = availableRows.map {
            BoardRow(quest: $0.quest, claimantName: $0.claimantName, isClaimedByCurrentUser: $0.isClaimedByCurrentUser, isPending: pending.contains($0.id))
        }
        claimedRows = claimedRows.map {
            BoardRow(quest: $0.quest, claimantName: $0.claimantName, isClaimedByCurrentUser: $0.isClaimedByCurrentUser, isPending: pending.contains($0.id))
        }
    }

    /// Detects lost claim races against ingested server state.
    private func settlePendingClaims() {
        let currentUser = currentUserRecordName
        let pending = pendingClaims
        var settled: Set<String> = []
        for recordName in pending {
            if let row = claimedRows.first(where: { $0.id == recordName }) {
                if let claimer = row.quest.claimedByProfileRecordName, claimer != currentUser {
                    // WHY single path: toast when wired, errorMessage fallback so previews never fail silently.
                    report(message: "Another hero claimed this quest", type: .info)
                }
                settled.insert(recordName)
            } else if availableRows.contains(where: { $0.id == recordName }) {
                // Still unclaimed on this pulse — keep pending until the
                // server-wins ingest confirms the winner.
                continue
            } else {
                // Quest no longer on board (deactivated) — drop pending.
                settled.insert(recordName)
            }
        }
        if !settled.isEmpty {
            pendingClaims.subtract(settled)
        }
    }

    /// WHY revoke settles on board return: ingest showing unclaimed confirms release.
    private func settlePendingRevokes() {
        let pending = pendingRevokes
        var settled: Set<String> = []
        for recordName in pending {
            if availableRows.contains(where: { $0.id == recordName }) {
                settled.insert(recordName)
            } else if claimedRows.contains(where: { $0.id == recordName }) {
                // WHY keep pending while still claimed: ingest has not confirmed release.
                continue
            } else {
                // WHY drop vanished rows: deactivated quests need no pending badge.
                settled.insert(recordName)
            }
        }
        if !settled.isEmpty {
            pendingRevokes.subtract(settled)
        }
    }

    /// Used by the view to disable the Claim button while a save is in flight.
    func isClaiming(_ row: BoardRow) -> Bool {
        // WHY stale snapshots must not report pending — current rows already carry it via isPending.
        row.isPending || inFlightClaims.contains(row.id) || isRevoking(row)
    }

    /// WHY shared disable: revoke pending must block claim and revoke taps alike.
    func isRevoking(_ row: BoardRow) -> Bool {
        // WHY stale snapshots must not report pending — current rows already carry it via isPending.
        row.isPending || inFlightRevokes.contains(row.id)
    }

    // MARK: - Actions

    func claim(_ row: BoardRow) async {
        // WHY row-first: mutation actor must mirror @Query rows so claim gating never reads stale session.
        let zoneID = appState.resolvedFamilyZoneID()
        let hero: Profile? = if let viewerRow {
            viewerRow.toProfile(zoneID: zoneID)
        } else {
            appState.currentProfile
        }
        guard let hero else { return }
        let id = row.id
        let (inserted, _) = inFlightClaims.insert(id)
        guard inserted else { return }
        defer { _ = inFlightClaims.remove(id) }
        _ = pendingClaims.insert(id)
        // WHY rows carry pending so the badge survives rebuilds.
        markPending(id)

        // WHY mutation boundary: snapshot converts here so presentation never holds domain structs.
        let quest = row.quest.toQuest(zoneID: zoneID)
        do {
            switch try await boardService.claim(quest, by: hero) {
            case .claimed:
                if let index = availableRows.firstIndex(where: { $0.id == row.id }) {
                    var claimedDomain = quest
                    claimedDomain.claimedByProfileRecordName = hero.id.recordName
                    claimedDomain.claimedAt = Date()
                    // WHY value copy: optimistic UI snapshots the domain so live storage never dirties.
                    let updatedRow = BoardRow(
                        quest: BoardQuestSnapshot(from: claimedDomain),
                        claimantName: hero.displayName,
                        isClaimedByCurrentUser: true,
                        isPending: true
                    )
                    availableRows.remove(at: index)
                    claimedRows.append(updatedRow)
                    claimedRows.sort { $0.quest.questName.localizedCaseInsensitiveCompare($1.quest.questName) == .orderedAscending }
                }
            case .lostToAnotherHero:
                handleLostClaim(id: id)
            }
        } catch BoardClaimError.lostToAnotherHero {
            // Optimistic UI rollback when claim lost to another hero.
            handleLostClaim(id: id)
        } catch {
            let fallback = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            handleFailure(id: id, message: fallback, isError: true) { _ = pendingClaims.remove(id) }
        }
    }

    /// WHY pending projects into rows so the badge renders without set lookups.
    private func markPending(_ id: String) {
        availableRows = availableRows.map {
            $0.id == id
                ? BoardRow(quest: $0.quest, claimantName: $0.claimantName, isClaimedByCurrentUser: $0.isClaimedByCurrentUser, isPending: true)
                : $0
        }
        claimedRows = claimedRows.map {
            $0.id == id
                ? BoardRow(quest: $0.quest, claimantName: $0.claimantName, isClaimedByCurrentUser: $0.isClaimedByCurrentUser, isPending: true)
                : $0
        }
    }

    /// WHY failed claims clear the badge on the surviving available row.
    private func clearPending(_ id: String) {
        availableRows = availableRows.map {
            $0.id == id
                ? BoardRow(quest: $0.quest, claimantName: $0.claimantName, isClaimedByCurrentUser: $0.isClaimedByCurrentUser, isPending: false)
                : $0
        }
        claimedRows = claimedRows.map {
            $0.id == id
                ? BoardRow(quest: $0.quest, claimantName: $0.claimantName, isClaimedByCurrentUser: $0.isClaimedByCurrentUser, isPending: false)
                : $0
        }
    }

    private func handleFailure(id: String, message: String, isError: Bool, cleanup: () -> Void) {
        cleanup()
        clearPending(id)
        // WHY single path: toast when wired, errorMessage fallback so previews never fail silently.
        report(message: message, type: isError ? .error : .info)
    }

    private func handleLostClaim(id: String) {
        handleFailure(id: id, message: "Another hero claimed this quest", isError: false) {
            _ = pendingClaims.remove(id)
        }
    }

    func revoke(_ row: BoardRow) async {
        let id = row.id
        let (inserted, _) = inFlightRevokes.insert(id)
        guard inserted else { return }
        defer { _ = inFlightRevokes.remove(id) }
        _ = pendingRevokes.insert(id)
        // WHY rows carry pending so the badge survives rebuilds.
        markPending(id)
        // WHY mutation boundary: snapshot converts here so presentation never holds domain structs.
        let zoneID = appState.resolvedFamilyZoneID()
        let quest = row.quest.toQuest(zoneID: zoneID)
        do {
            try await boardService.revoke(quest)
            if let index = claimedRows.firstIndex(where: { $0.id == row.id }) {
                var revokedDomain = quest
                revokedDomain.claimedByProfileRecordName = nil
                revokedDomain.claimedAt = nil
                // WHY value copy: optimistic UI snapshots the domain so live storage never dirties.
                let updatedRow = BoardRow(
                    quest: BoardQuestSnapshot(from: revokedDomain),
                    claimantName: nil,
                    isClaimedByCurrentUser: false,
                    isPending: true
                )
                claimedRows.remove(at: index)
                availableRows.append(updatedRow)
                availableRows.sort { $0.quest.questName.localizedCaseInsensitiveCompare($1.quest.questName) == .orderedAscending }
            }
        } catch {
            let fallback = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            handleFailure(id: id, message: fallback, isError: true) { _ = pendingRevokes.remove(id) }
        }
    }
}

/// WHY single path: toast when wired, errorMessage fallback so previews never fail silently.
extension HeroBoardViewModel: ToastReporting {
    var toastManager: ToastManager? {
        boardService.toastManager
    }

    func setReportMessage(_ message: String) {
        errorMessage = message
    }
}

/// WHY value snapshot: board rows render Sendable copies snapshotted on isolation, never live @Model references.
struct BoardQuestSnapshot: Sendable, Equatable, Hashable {
    let recordName: String
    let familyRecordName: String
    let assigneeRecordName: String
    let templateRecordName: String
    let weekOf: Date
    let questName: String
    let isActive: Bool
    let goldReward: Int64
    let xpReward: Int
    let xpBanked: Int
    let rarity: String
    let scheduleType: String
    let targetCount: Int
    let isAllOrNothing: Bool
    let approvalMode: String
    let descriptionText: String?
    let createdByRecordName: String
    let claimedByProfileRecordName: String?
    let claimedAt: Date?
    let changeTag: String?

    init(from cached: QuestCache) {
        recordName = cached.recordName
        familyRecordName = cached.familyRecordName
        assigneeRecordName = cached.assigneeRecordName
        templateRecordName = cached.templateRecordName
        weekOf = cached.weekOf
        questName = cached.questName
        isActive = cached.isActive
        goldReward = cached.goldReward
        xpReward = cached.xpReward
        xpBanked = cached.xpBanked
        rarity = cached.rarity
        scheduleType = cached.scheduleType
        targetCount = cached.targetCount
        isAllOrNothing = cached.isAllOrNothing
        approvalMode = cached.approvalMode
        descriptionText = cached.descriptionText
        createdByRecordName = cached.createdByRecordName
        claimedByProfileRecordName = cached.claimedByProfileRecordName
        claimedAt = cached.claimedAt
        changeTag = cached.changeTag
    }

    init(from quest: Quest) {
        recordName = quest.id.recordName
        familyRecordName = quest.family.recordID.recordName
        assigneeRecordName = quest.assignee.recordID.recordName
        templateRecordName = quest.template.recordID.recordName
        weekOf = quest.weekOf
        questName = quest.displayName
        isActive = quest.active
        goldReward = quest.goldReward
        xpReward = quest.xpReward
        xpBanked = quest.xpBanked
        rarity = quest.rarity.rawValue
        scheduleType = quest.scheduleType.rawValue
        targetCount = quest.targetCount
        isAllOrNothing = quest.isAllOrNothing
        approvalMode = quest.approvalMode.rawValue
        descriptionText = quest.descriptionText
        createdByRecordName = quest.createdBy.recordID.recordName
        claimedByProfileRecordName = quest.claimedByProfileRecordName
        claimedAt = quest.claimedAt
        changeTag = quest.changeTag
    }

    /// WHY boundary-only: snapshot rebuilds the domain for claim/revoke without touching live storage.
    func toQuest(zoneID: CKRecordZone.ID) -> Quest {
        var quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: templateRecordName, zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: CKRecord.ID(recordName: assigneeRecordName, zoneID: zoneID), action: .none),
            goldReward: goldReward,
            xpReward: xpReward,
            scheduleType: QuestSchedule(rawValue: scheduleType) ?? .weeklyFlexible,
            targetCount: targetCount,
            isAllOrNothing: isAllOrNothing,
            approvalMode: ApprovalMode(rawValue: approvalMode) ?? .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: createdByRecordName, zoneID: zoneID), action: .none),
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), action: .none),
            name: questName,
            descriptionText: descriptionText,
            xpBanked: xpBanked,
            claimedByProfileRecordName: claimedByProfileRecordName,
            claimedAt: claimedAt,
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
        quest.changeTag = changeTag
        return quest
    }
}
