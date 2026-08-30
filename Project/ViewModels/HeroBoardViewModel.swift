//
//  HeroBoardViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation
import Observation
import Synchronization

@MainActor
@Observable
final class HeroBoardViewModel {
    struct BoardRow: Identifiable, Equatable {
        let quest: Quest
        let claimantName: String?
        let isClaimedByCurrentUser: Bool

        var id: String {
            quest.id.recordName
        }
    }

    private(set) var availableRows: [BoardRow] = []
    private(set) var claimedRows: [BoardRow] = []

    /// Record names of quests this device has optimistically claimed but whose
    /// save has not yet been acknowledged. If ingest later reveals another
    /// claimer for one of these, the child sees the lost-race toast.
    /// WHY: Mutex protects against concurrent Task { await claim(row) } double-tap interleaving on @MainActor.
    private let pendingClaims = Mutex<Set<String>>([])

    /// Record names with a claim save currently in flight on this device.
    /// WHY: Mutex serializes the check-insert-remove around the await so a second tap cannot slip between isClaiming and insert.
    private let inFlightClaims = Mutex<Set<String>>([])

    private let boardService: HeroBoardService
    private let appState: AppState

    var isParent: Bool {
        appState.currentProfile?.role.isParent ?? false
    }

    private var currentUserRecordName: String? {
        appState.currentProfile?.id.recordName
    }

    init(boardService: HeroBoardService, appState: AppState) {
        self.boardService = boardService
        self.appState = appState
    }

    // MARK: - Load

    /// Rebuilds board rows from the SwiftData cache the view observes via
    /// `@Query`. Also settles optimistic claims: if a pending claim now shows
    /// another claimer (their server-wins ingest landed), surface the toast.
    func rebuildLists(quests: [QuestCache], profiles: [ProfileCache]) {
        guard let family = appState.family else {
            availableRows = []
            claimedRows = []
            pendingClaims.withLock { $0.removeAll() }
            return
        }

        let profileByName = Dictionary(uniqueKeysWithValues: profiles.map { ($0.recordName, $0) })
        let currentUser = currentUserRecordName

        let rows: [BoardRow] = quests.compactMap { cached in
            let zoneID = cached.validatedZoneID(requestedZoneID: family.id.zoneID)
            let quest = cached.toQuest(zoneID: zoneID)
            guard cached.isActive, HeroBoardService.isBoardQuest(quest) else { return nil }
            let claimer = quest.claimedByProfileRecordName
            return BoardRow(
                quest: quest,
                claimantName: claimer.flatMap { profileByName[$0]?.displayName },
                isClaimedByCurrentUser: claimer == currentUser
            )
        }
        .sorted { $0.quest.displayName.localizedCaseInsensitiveCompare($1.quest.displayName) == .orderedAscending }

        availableRows = rows.filter { $0.quest.claimedByProfileRecordName == nil }
        claimedRows = rows.filter { $0.quest.claimedByProfileRecordName != nil }

        settlePendingClaims()
    }

    /// Detects lost claim races against ingested server state. The lists are
    /// already rebuilt from cache at this point — the refresh itself is free.
    /// WHY: Only clears pending entries that have settled (now claimed) so a
    /// local optimistic write that hasn't yet been confirmed does not lose its
    /// pending marker before the server-wins ingest pulse arrives.
    private func settlePendingClaims() {
        let currentUser = currentUserRecordName
        let pending = pendingClaims.withLock { $0 }
        var settled: Set<String> = []
        for recordName in pending {
            if let row = claimedRows.first(where: { $0.id == recordName }) {
                if let claimer = row.quest.claimedByProfileRecordName, claimer != currentUser {
                    boardService.toastManager?.show(
                        message: "Someone grabbed it first!",
                        type: .warning
                    )
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

    /// Used by the view to disable the Claim button while a save is in flight.
    func isClaiming(_ row: BoardRow) -> Bool {
        inFlightClaims.withLock { $0.contains(row.id) }
    }

    // MARK: - Actions

    func claim(_ row: BoardRow) async {
        guard let hero = appState.currentProfile else { return }
        let id = row.id
        // WHY: Early guard + insert before the await prevents concurrent Tasks from the same double-tap interleaving.
        let inserted = inFlightClaims.withLock { $0.insert(id).inserted }
        guard inserted else { return }
        defer { _ = inFlightClaims.withLock { $0.remove(id) } }
        pendingClaims.withLock { _ = $0.insert(id) }

        do {
            switch try await boardService.claim(row.quest, by: hero) {
            case .claimed:
                // Server-wins resolver owns the race: local cache was already
                // updated optimistically and enqueued; the VM observes the
                // cache pulse via rebuildLists rather than assuming success.
                break
            case .lostToAnotherHero:
                pendingClaims.withLock { _ = $0.remove(id) }
                boardService.toastManager?.show(message: "Someone grabbed it first!", type: .warning)
            }
        } catch let ckError as CKError where ckError.code == .serverRecordChanged {
            // WHY: Optimistic UI rollback on serverRecordChanged — the
            // resolver merges via ingest and the cache pulse reveals the
            // winner; do not keep an optimistic row that the server rejected.
            pendingClaims.withLock { _ = $0.remove(id) }
            boardService.toastManager?.show(message: "Someone grabbed it first!", type: .warning)
        } catch {
            pendingClaims.withLock { _ = $0.remove(id) }
            boardService.toastManager?.show(
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                type: .error
            )
        }
    }

    func revoke(_ row: BoardRow) async {
        do {
            try await boardService.revoke(row.quest)
            if let index = claimedRows.firstIndex(where: { $0.id == row.id }) {
                var revokedQuest = row.quest
                revokedQuest.claimedByProfileRecordName = nil
                revokedQuest.claimedAt = nil
                let updatedRow = BoardRow(
                    quest: revokedQuest,
                    claimantName: nil,
                    isClaimedByCurrentUser: false
                )
                claimedRows.remove(at: index)
                availableRows.append(updatedRow)
                availableRows.sort { $0.quest.displayName.localizedCaseInsensitiveCompare($1.quest.displayName) == .orderedAscending }
            }
        } catch {
            boardService.toastManager?.show(
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                type: .error
            )
        }
    }
}
