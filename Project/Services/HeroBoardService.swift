//
//  HeroBoardService.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation
import os
import Synchronization

/// Outcome of a board-claim attempt. A lost race is not an error: server-wins
/// conflict resolution reveals the other claimer via ingest, so the loser
/// simply re-renders.
enum HeroBoardClaimOutcome: Equatable, Sendable {
    case claimed
    case lostToAnotherHero
}

@MainActor
@Observable
final class HeroBoardService {
    /// Placeholder assignee for unassigned Hero Board quests.
    static let boardAssigneeRecordName = "__heroboard__"

    /// True when the quest is posted on the Hero Board (unassigned).
    static func isBoardQuest(_ quest: Quest) -> Bool {
        quest.assignee.recordID.recordName == boardAssigneeRecordName
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "HeroBoard")

    private let questService: QuestService
    let cacheService: CacheService
    let syncCoordinator: CKSyncEngineCoordinator
    let appState: AppState

    private var cloudKit: any CloudKitServiceProtocol {
        questService.cloudKitReference
    }

    var toastManager: ToastManager? {
        questService.toastManager
    }

    /// Record names of quests with a claim save currently in flight. Local
    /// double-submit guard: a second tap for the same quest while the first
    /// save is pending is a no-op instead of a duplicate write.
    private let inFlightClaims = Mutex<Set<String>>([])

    init(
        questService: QuestService,
        cacheService: CacheService,
        syncCoordinator: CKSyncEngineCoordinator,
        appState: AppState
    ) {
        self.questService = questService
        self.cacheService = cacheService
        self.syncCoordinator = syncCoordinator
        self.appState = appState
    }

    /// Convenience for read-only callers and legacy ViewModel init paths that
    /// construct via QuestService alone. Resolves mandatory dependencies from
    /// the already-wired QuestService instance.
    convenience init(questService: QuestService) {
        self.init(
            questService: questService,
            cacheService: questService.cacheService,
            syncCoordinator: questService.syncCoordinator,
            appState: questService.appState
        )
    }

    // MARK: - Reads

    /// Fetches active unassigned quests available on the Hero Board.
    func fetchBoardQuests(family: Family) -> [Quest] {
        cacheService.fetchQuests(family: family.id.recordName)
            .filter(\.isActive)
            .map { $0.toQuest(zoneID: family.id.zoneID) }
            .filter(Self.isBoardQuest)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Unclaimed board quests available for any hero to grab.
    func fetchAvailableBoardQuests(family: Family) -> [Quest] {
        fetchBoardQuests(family: family).filter { $0.claimedByProfileRecordName == nil }
    }

    /// Board quests already claimed, grouped by claiming hero's record name.
    func fetchClaimedBoardQuests(family: Family) -> [String: [Quest]] {
        var grouped: [String: [Quest]] = [:]
        for quest in fetchBoardQuests(family: family) {
            if let claimer = quest.claimedByProfileRecordName {
                grouped[claimer, default: []].append(quest)
            }
        }
        return grouped
    }

    // MARK: - Claims

    /// Optimistically stamps quest claim in local cache and enqueues CloudKit save.
    /// WHY: Hero Board claim races resolve via standard server-wins conflict
    /// resolution; the loser's ingest reveals the other claimer. The ViewModel
    /// observes the cache pulse and rolls back optimistic UI on
    /// CKError.serverRecordChanged rather than assuming this local write won.
    @discardableResult
    func claim(_ quest: Quest, by hero: Profile) async throws -> HeroBoardClaimOutcome {
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRef: quest.family,
            zoneID: quest.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )

        let key = quest.id.recordName
        let inserted = inFlightClaims.withLock { $0.insert(key).inserted }
        defer { _ = inFlightClaims.withLock { $0.remove(key) } }
        guard inserted else {
            // Same-device double-tap while the first save is pending: the
            // optimistic row is already ours.
            return .claimed
        }

        var current = quest
        if let cached = cacheService.fetchQuest(recordName: key, family: quest.family.recordID.recordName) {
            current = cached.toQuest(zoneID: quest.id.zoneID)
        }

        if let claimer = current.claimedByProfileRecordName, !claimer.isEmpty {
            if claimer == hero.id.recordName {
                return .claimed
            }
            logger.info("Claim race lost for \(key, privacy: .private)")
            return .lostToAnotherHero
        }

        current.claimedByProfileRecordName = hero.id.recordName
        current.claimedAt = Date()

        await cacheService.upsertQuest(current)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: current.id, appState: appState, logger: logger, context: "HeroBoardService.claim")
        return .claimed
    }

    /// Parent-only: releases a claimed quest back to the board by clearing its
    /// claim fields. The placeholder assignee is untouched, so the quest stays
    /// on the board surface.
    func revoke(_ quest: Quest) async throws {
        guard let acting = appState.currentProfile,
              acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRef: quest.family,
            zoneID: quest.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )

        var released = quest
        // Revoke against the freshest cached copy so unrelated field edits
        // that synced since this view loaded are not clobbered.
        if let cached = cacheService.fetchQuest(recordName: quest.id.recordName, family: quest.family.recordID.recordName) {
            released = cached.toQuest(zoneID: quest.id.zoneID)
        }
        released.claimedByProfileRecordName = nil
        released.claimedAt = nil

        await cacheService.upsertQuest(released)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: released.id, appState: appState, logger: logger, context: "HeroBoardService.revoke")
    }

    // MARK: - Posting

    /// Creates unassigned board quest with nil assignee (parent only).
    @discardableResult
    func postToBoard(name: String,
                     description: String = "",
                     goldReward: Double,
                     xpReward: Int,
                     approvalMode: ApprovalMode = .autoApprove,
                     createdBy: Profile,
                     family: Family) async throws -> Quest
    {
        guard let acting = appState.currentProfile,
              acting.id == createdBy.id,
              acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }
        guard createdBy.family.recordID == family.id,
              createdBy.id.zoneID == family.id.zoneID
        else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            throw QuestServiceError.staleData("Board quest name must not be empty")
        }

        let adhocTemplate = try await questService.createTemplate(
            name: trimmedName,
            description: description,
            defaultGold: goldReward,
            xpReward: xpReward,
            schedule: .weeklyFlexible,
            specificDays: [],
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: approvalMode,
            createdBy: createdBy,
            family: family
        )
        _ = try await questService.deactivateTemplate(adhocTemplate)

        let quest = Quest(
            template: CKRecord.Reference(recordID: adhocTemplate.id, action: .none),
            assignee: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: Self.boardAssigneeRecordName, zoneID: family.id.zoneID),
                action: .none
            ),
            goldReward: goldReward,
            xpReward: xpReward,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: approvalMode,
            weekOf: WeekMath.startOfWeek(for: Date(), payoutDay: family.payoutDay),
            createdBy: CKRecord.Reference(recordID: createdBy.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: trimmedName,
            descriptionText: description,
            id: CKRecord.ID(recordName: UUID().uuidString, zoneID: family.id.zoneID)
        )

        await cacheService.upsertQuest(quest)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: quest.id, appState: appState, logger: logger, context: "HeroBoardService.postToBoard")
        return quest
    }
}
