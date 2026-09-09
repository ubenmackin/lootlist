//
//  HeroBoardViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import Foundation
import Observation
import Synchronization

@MainActor
@Observable
final class HeroBoardViewModel {
    struct BoardRow: Identifiable, Equatable {
        let quest: QuestCache
        let claimantName: String?
        let isClaimedByCurrentUser: Bool
        let isPending: Bool

        init(quest: QuestCache, claimantName: String?, isClaimedByCurrentUser: Bool, isPending: Bool = false) {
            self.quest = quest
            self.claimantName = claimantName
            self.isClaimedByCurrentUser = isClaimedByCurrentUser
            self.isPending = isPending
        }

        /// Test/legacy bridge: converts the domain snapshot to cache at the boundary so rows never hold domain.
        init(quest: Quest, claimantName: String?, isClaimedByCurrentUser: Bool, isPending: Bool = false) {
            self.init(quest: QuestCache(from: quest), claimantName: claimantName, isClaimedByCurrentUser: isClaimedByCurrentUser, isPending: isPending)
        }

        var id: String {
            quest.recordName
        }

        /// WHY value snapshot: QuestCache is a reference type, so compare rendered fields.
        static func == (lhs: BoardRow, rhs: BoardRow) -> Bool {
            lhs.quest.recordName == rhs.quest.recordName &&
                lhs.claimantName == rhs.claimantName &&
                lhs.isClaimedByCurrentUser == rhs.isClaimedByCurrentUser &&
                lhs.isPending == rhs.isPending &&
                lhs.quest.questName == rhs.quest.questName &&
                lhs.quest.goldReward == rhs.quest.goldReward &&
                lhs.quest.xpReward == rhs.quest.xpReward &&
                lhs.quest.xpBanked == rhs.quest.xpBanked &&
                lhs.quest.descriptionText == rhs.quest.descriptionText &&
                lhs.quest.isAllOrNothing == rhs.quest.isAllOrNothing &&
                lhs.quest.weekOf == rhs.quest.weekOf &&
                lhs.quest.claimedByProfileRecordName == rhs.quest.claimedByProfileRecordName &&
                lhs.quest.claimedAt == rhs.quest.claimedAt &&
                lhs.quest.changeTag == rhs.quest.changeTag &&
                lhs.quest.isActive == rhs.quest.isActive &&
                lhs.quest.assigneeRecordName == rhs.quest.assigneeRecordName &&
                lhs.quest.templateRecordName == rhs.quest.templateRecordName &&
                lhs.quest.targetCount == rhs.quest.targetCount &&
                lhs.quest.scheduleType == rhs.quest.scheduleType &&
                lhs.quest.approvalMode == rhs.quest.approvalMode &&
                lhs.quest.familyRecordName == rhs.quest.familyRecordName &&
                lhs.quest.createdByRecordName == rhs.quest.createdByRecordName &&
                lhs.quest.rarity == rhs.quest.rarity
        }
    }

    private(set) var availableRows: [BoardRow] = []
    private(set) var claimedRows: [BoardRow] = []
    private(set) var errorMessage: String?

    /// Record names of quests optimistically claimed on this device awaiting save confirmation.
    private let pendingClaims = Mutex<Set<String>>([])

    /// Record names with a claim save currently in flight on this device.
    private let inFlightClaims = Mutex<Set<String>>([])

    /// Record names of quests optimistically revoked on this device awaiting save confirmation.
    private let pendingRevokes = Mutex<Set<String>>([])

    /// Record names with a revoke save currently in flight on this device.
    private let inFlightRevokes = Mutex<Set<String>>([])

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
            pendingClaims.withLock { $0.removeAll() }
            pendingRevokes.withLock { $0.removeAll() }
            return
        }

        let profileByName = Dictionary(uniqueKeysWithValues: profiles.map { ($0.recordName, $0) })
        let currentUser = currentUserRecordName
        // WHY optimistic rows stay visible while the claim save confirms.
        let pending = pendingRecordNames()

        // WHY cache-first: rows hold QuestCache for presentation; domain conversion happens only at claim/revoke.
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
        let claims = pendingClaims.withLock { $0 }
        let claimsFlight = inFlightClaims.withLock { $0 }
        let revokes = pendingRevokes.withLock { $0 }
        let revokesFlight = inFlightRevokes.withLock { $0 }
        return claims.union(claimsFlight).union(revokes).union(revokesFlight)
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
        let pending = pendingClaims.withLock { $0 }
        var settled: Set<String> = []
        for recordName in pending {
            if let row = claimedRows.first(where: { $0.id == recordName }) {
                if let claimer = row.quest.claimedByProfileRecordName, claimer != currentUser {
                    let message = "Another hero claimed this quest"
                    errorMessage = message
                    boardService.toastManager?.show(
                        message: message,
                        type: .info
                    )
                    // Fallback when no ToastManager is wired (e.g. previews/tests without environment).
                    if boardService.toastManager == nil {
                        errorMessage = message
                    }
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
            pendingClaims.withLock { $0.subtract(settled) }
        }
    }

    /// WHY revoke settles on board return: ingest showing unclaimed confirms release.
    private func settlePendingRevokes() {
        let pending = pendingRevokes.withLock { $0 }
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
            pendingRevokes.withLock { $0.subtract(settled) }
        }
    }

    /// Used by the view to disable the Claim button while a save is in flight.
    func isClaiming(_ row: BoardRow) -> Bool {
        // WHY stale snapshots must not report pending — current rows already carry it via isPending.
        row.isPending || inFlightClaims.withLock { $0.contains(row.id) } || isRevoking(row)
    }

    /// WHY shared disable: revoke pending must block claim and revoke taps alike.
    func isRevoking(_ row: BoardRow) -> Bool {
        // WHY stale snapshots must not report pending — current rows already carry it via isPending.
        row.isPending || inFlightRevokes.withLock { $0.contains(row.id) }
    }

    // MARK: - Actions

    func claim(_ row: BoardRow) async {
        // WHY row-first: mutation actor must mirror @Query rows so claim gating never reads stale session.
        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: row.quest)
        let hero: Profile? = if let viewerRow {
            viewerRow.toProfile(zoneID: zoneID)
        } else {
            appState.currentProfile
        }
        guard let hero else { return }
        let id = row.id
        let inserted = inFlightClaims.withLock { $0.insert(id).inserted }
        guard inserted else { return }
        defer { _ = inFlightClaims.withLock { $0.remove(id) } }
        pendingClaims.withLock { _ = $0.insert(id) }
        // WHY rows carry pending so the badge survives rebuilds.
        markPending(id)

        // WHY mutation boundary: domain conversion happens here so presentation never holds domain structs.
        let quest = row.quest.toQuest(zoneID: zoneID)
        do {
            switch try await boardService.claim(quest, by: hero) {
            case .claimed:
                if let index = availableRows.firstIndex(where: { $0.id == row.id }) {
                    var claimedDomain = quest
                    claimedDomain.claimedByProfileRecordName = hero.id.recordName
                    claimedDomain.claimedAt = Date()
                    // WHY detached copy: mutating the @Query row would dirty SwiftData, so optimistic UI copies.
                    let updatedRow = BoardRow(
                        quest: QuestCache(from: claimedDomain),
                        claimantName: hero.displayName,
                        isClaimedByCurrentUser: true,
                        isPending: true
                    )
                    availableRows.remove(at: index)
                    claimedRows.append(updatedRow)
                    claimedRows.sort { $0.quest.questName.localizedCaseInsensitiveCompare($1.quest.questName) == .orderedAscending }
                }
            case .lostToAnotherHero:
                pendingClaims.withLock { _ = $0.remove(id) }
                clearPending(id)
                let message = "Another hero claimed this quest"
                errorMessage = message
                boardService.toastManager?.show(message: message, type: .info)
                // Ensure stale pending state does not linger when toast is unavailable.
                if boardService.toastManager == nil {
                    errorMessage = message
                }
            }
        } catch BoardClaimError.lostToAnotherHero {
            // Optimistic UI rollback when claim lost to another hero.
            pendingClaims.withLock { _ = $0.remove(id) }
            clearPending(id)
            let message = "Another hero claimed this quest"
            errorMessage = message
            boardService.toastManager?.show(message: message, type: .info)
            if boardService.toastManager == nil {
                errorMessage = message
            }
        } catch {
            pendingClaims.withLock { _ = $0.remove(id) }
            clearPending(id)
            let fallback = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = fallback
            boardService.toastManager?.show(
                message: fallback,
                type: .error
            )
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

    func revoke(_ row: BoardRow) async {
        let id = row.id
        let inserted = inFlightRevokes.withLock { $0.insert(id).inserted }
        guard inserted else { return }
        defer { _ = inFlightRevokes.withLock { $0.remove(id) } }
        pendingRevokes.withLock { _ = $0.insert(id) }
        // WHY rows carry pending so the badge survives rebuilds.
        markPending(id)
        // WHY mutation boundary: domain conversion happens here so presentation never holds domain structs.
        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: row.quest)
        let quest = row.quest.toQuest(zoneID: zoneID)
        do {
            try await boardService.revoke(quest)
            if let index = claimedRows.firstIndex(where: { $0.id == row.id }) {
                var revokedDomain = quest
                revokedDomain.claimedByProfileRecordName = nil
                revokedDomain.claimedAt = nil
                // WHY detached copy: mutating the @Query row would dirty SwiftData, so optimistic UI copies.
                let updatedRow = BoardRow(
                    quest: QuestCache(from: revokedDomain),
                    claimantName: nil,
                    isClaimedByCurrentUser: false,
                    isPending: true
                )
                claimedRows.remove(at: index)
                availableRows.append(updatedRow)
                availableRows.sort { $0.quest.questName.localizedCaseInsensitiveCompare($1.quest.questName) == .orderedAscending }
            }
        } catch {
            pendingRevokes.withLock { _ = $0.remove(id) }
            clearPending(id)
            let fallback = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = fallback
            boardService.toastManager?.show(
                message: fallback,
                type: .error
            )
        }
    }
}
