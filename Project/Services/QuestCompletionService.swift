//
//  QuestCompletionService.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import CloudKit
import Foundation
import os
import Synchronization

/// WHY single-sourced: XP credit and deterministic reward minting ride QuestRewardService.
@MainActor
@Observable
final class QuestCompletionService {
    let logger = Logger(category: "QuestCompletionService")
    let cloudKit: any CloudKitServiceProtocol
    var cacheService: CacheService
    var appState: AppState
    var syncCoordinator: any SyncEnqueuing
    let xpService: XPService
    let notificationService: NotificationService?
    var achievementService: AchievementService?
    let toastManager: ToastManager?
    var rewardService: QuestRewardService

    /// Guards against double-submit completions while a save is pending.
    let inFlightCompletions: Mutex<Set<String>>
    /// Record names of quest completions with a verify/reject action currently in flight.
    let inFlightVerifications: Mutex<Set<String>>
    /// Record names of quest completions with a withdrawal action currently in flight.
    let inFlightWithdrawals: Mutex<Set<String>>

    init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService,
        appState: AppState,
        syncCoordinator: any SyncEnqueuing,
        xpService: XPService,
        notificationService: NotificationService? = nil,
        achievementService: AchievementService? = nil,
        toastManager: ToastManager? = nil,
        rewardService: QuestRewardService,
        inFlightCompletions: consuming Mutex<Set<String>> = Mutex([]),
        inFlightVerifications: consuming Mutex<Set<String>> = Mutex([]),
        inFlightWithdrawals: consuming Mutex<Set<String>> = Mutex([])
    ) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
        self.xpService = xpService
        self.notificationService = notificationService
        self.achievementService = achievementService
        self.toastManager = toastManager
        self.rewardService = rewardService
        self.inFlightCompletions = inFlightCompletions
        self.inFlightVerifications = inFlightVerifications
        self.inFlightWithdrawals = inFlightWithdrawals
    }

    // MARK: - Quest Completions & Verification

    @discardableResult
    func markComplete(quest: QuestCache, by profile: Profile, at completedDate: Date = Date()) async throws -> QuestCompletion {
        guard let zoneID = appState.familyZoneID else {
            logger.warning("markComplete aborted: no active family zone")
            throw FamilyServiceError.unauthorized
        }
        return try await markComplete(quest: quest.toQuest(zoneID: zoneID), by: profile, at: completedDate)
    }

    @discardableResult
    func markComplete(quest: Quest, by profile: Profile, at completedDate: Date = Date()) async throws -> QuestCompletion {
        // WHY single gate: self-acting plus scope share one helper so unauthorized versus scope-violation never drifts.
        let acting: Profile
        do {
            acting = try ActiveFamilyScopeGuard.requireMutationContext(
                appState: appState,
                familyRef: quest.family,
                zoneID: quest.id.zoneID,
                cloudKit: cloudKit,
                expectedSelf: profile
            )
        } catch let error as FamilyServiceError {
            logger.warning("markComplete aborted: acting profile mismatch for quest \(quest.id.recordName, privacy: .private)")
            throw error
        }
        guard quest.assignee.recordID.recordName == profile.id.recordName || acting.role.isParent else {
            logger.warning("markComplete aborted: assignee mismatch for quest \(quest.id.recordName, privacy: .private)")
            throw FamilyServiceError.unauthorized
        }
        guard profile.family.recordID == quest.family.recordID,
              profile.id.zoneID == quest.id.zoneID
        else {
            logger.warning("markComplete aborted: family/zone mismatch for quest \(quest.id.recordName, privacy: .private)")
            throw FamilyServiceError.unauthorized
        }
        let questName = quest.id.recordName
        let inserted = inFlightCompletions.withLock { $0.insert(questName).inserted }
        guard inserted else {
            toastManager?.show(message: "This quest is already being completed.", type: .info)
            throw QuestServiceError.alreadyInFlight
        }
        defer { inFlightCompletions.withLock { _ = $0.remove(questName) } }

        try await validateCanCompleteQuest(quest, questName: questName)

        let resolvedZoneID: CKRecordZone.ID = {
            guard let activeZone = appState.familyZoneID else { return quest.id.zoneID }
            if quest.id.zoneID != activeZone {
                let qZone = quest.id.zoneID.zoneName
                let aZone = activeZone.zoneName
                logger.warning("markComplete zone mismatch: quest \(qZone, privacy: .private) != active \(aZone, privacy: .private) — using activeZone")
            }
            return activeZone
        }()
        // WHY random UUID: each tap is a distinct event; repeats collapse via inFlight + target validation while rewards stay idempotent on reward-{completionID}.
        var log = QuestCompletion(
            quest: CKRecord.Reference(recordID: CKRecord.ID(recordName: quest.id.recordName, zoneID: resolvedZoneID), action: .none),
            completedBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: profile.id.recordName, zoneID: resolvedZoneID), action: .none),
            approvalMode: quest.approvalMode,
            weekOf: quest.weekOf,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: quest.family.recordID.recordName, zoneID: resolvedZoneID), action: .none),
            id: CKRecord.ID(recordName: UUID().uuidString, zoneID: resolvedZoneID)
        )
        log.completedDate = completedDate

        let existingLogs = cachedQuestLogs(forQuest: quest)
        let priorCount = existingLogs.filter(\.verificationStatus.countsTowardCompletion).count
        // WHY day count wins: legacy rows keep stale targetCount after template gains days.
        let templatesByID = SpecificDaysHelper.templatesByID(cache: cacheService, familyName: quest.family.recordID.recordName, zoneID: quest.id.zoneID)
        let effectiveTarget = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
        let isFinalSubPart = GoldCalculation.isFullyCompleted(quest: quest, approvedCount: priorCount + 1, effectiveTarget: effectiveTarget)

        switch quest.approvalMode {
        case .autoApprove:
            log = try await completeAutoApprove(log: log, quest: quest, profile: profile, resolvedZoneID: resolvedZoneID)
        case .parentVerify:
            log = try await completeParentVerify(log: log, quest: quest, isFinalSubPart: isFinalSubPart, resolvedZoneID: resolvedZoneID)
        }
        Task { [weak self] in await self?.syncCoordinator.sendPendingChanges() }
        return log
    }

    // MARK: - Completion Mode Helpers

    private func completeAutoApprove(log: QuestCompletion, quest: Quest, profile: Profile, resolvedZoneID: CKRecordZone.ID) async throws
        -> QuestCompletion
    {
        var mutableLog = log
        mutableLog.verificationStatus = .autoApproved
        await cacheService.upsertQuestCompletion(mutableLog)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: mutableLog.id,
            appState: appState,
            logger: logger,
            context: "QuestCompletionService.completeQuest.autoApproved"
        )
        let baselineXP = cacheService.fetchProfile(recordName: profile.id.recordName, family: quest.family.recordID.recordName)?
            .xpTotal ?? profile.xp
        var awardApplied = false
        var awardedXPCredited: Int?
        do {
            _ = try await rewardService.applyReward(for: quest, to: profile, completion: mutableLog)
            if let cached = cacheService.fetchQuestCompletion(recordName: mutableLog.id.recordName, family: quest.family.recordID.recordName) {
                mutableLog = cached.toQuestCompletion(zoneID: resolvedZoneID)
                awardedXPCredited = cached.xpCredited
                awardApplied = true
            }
        } catch {
            if CloudKitErrorClassifier.isTransient(error) {
                return try await handleAutoApproveTransient(
                    log: mutableLog,
                    quest: quest,
                    profile: profile,
                    resolvedZoneID: resolvedZoneID
                )
            }
            try await handleAutoApproveHardRollback(
                log: mutableLog,
                quest: quest,
                profile: profile,
                resolvedZoneID: resolvedZoneID,
                baselineXP: baselineXP,
                awardApplied: awardApplied,
                awardedXPCredited: awardedXPCredited,
                error: error
            )
            throw error
        }
        if let cached = cacheService.fetchQuestCompletion(recordName: mutableLog.id.recordName, family: quest.family.recordID.recordName) {
            mutableLog = cached.toQuestCompletion(zoneID: resolvedZoneID)
        }
        return mutableLog
    }

    private func handleAutoApproveTransient(log: QuestCompletion, quest: Quest, profile: Profile, resolvedZoneID: CKRecordZone.ID)
        async throws -> QuestCompletion
    {
        var mutableLog = log
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: mutableLog.id,
            appState: appState,
            logger: logger,
            context: "QuestCompletionService.completeQuest.autoApproved.transient"
        )
        if cacheService.fetchQuestCompletion(recordName: mutableLog.id.recordName, family: quest.family.recordID.recordName)?.xpCredited == nil {
            try await applyTransientFallbackCredit(log: &mutableLog, quest: quest, profile: profile, resolvedZoneID: resolvedZoneID)
        }
        toastManager?.show(message: "Quest completion queued — will sync when online.", type: .info)
        Task { [weak self] in await self?.syncCoordinator.sendPendingChanges() }
        return mutableLog
    }

    private func applyTransientFallbackCredit(log: inout QuestCompletion, quest: Quest, profile: Profile, resolvedZoneID: CKRecordZone.ID)
        async throws
    {
        let logs: [QuestCompletion]
        do {
            logs = try await fetchQuestLogs(forQuest: quest, useCache: true)
        } catch {
            logger.warning("Failed to fetch cached quest logs for quest \(quest.id.recordName, privacy: .private): \(error, privacy: .private); proceeding with empty logs")
            logs = []
        }
        let approvedLogs = logs.filter { $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved }
        let priorApproved = approvedLogs.count
        let alreadyCounted = approvedLogs.contains { $0.id.recordName == log.id.recordName }
        let approvedCount = alreadyCounted ? max(1, priorApproved) : max(1, priorApproved + 1)
        guard let currentQuest = cacheService.fetchQuest(recordName: quest.id.recordName, family: quest.family.recordID.recordName)?
            .toQuest(zoneID: resolvedZoneID)
        else {
            return
        }
        let remaining = GoldCalculation.marginalXPCredit(for: currentQuest, approvedCount: approvedCount, alreadyCredited: currentQuest.xpBanked)
        if remaining > 0 {
            try await creditTransientReward(log: &log, quest: quest, profile: profile, resolvedZoneID: resolvedZoneID, approvedCount: approvedCount, remaining: remaining)
        } else if remaining == 0 {
            var stamped = log
            stamped.xpCredited = 0
            await cacheService.upsertQuestCompletion(stamped)
            ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
                syncCoordinator,
                id: stamped.id,
                appState: appState,
                logger: logger,
                context: "QuestCompletionService.completeQuest.autoApproved.transient.stampZero"
            )
        }
    }

    private func creditTransientReward(
        log: inout QuestCompletion,
        quest: Quest,
        profile: Profile,
        resolvedZoneID: CKRecordZone.ID,
        approvedCount: Int,
        remaining: Int
    ) async throws {
        guard let heroProfile = cacheService.fetchProfile(recordName: profile.id.recordName, family: quest.family.recordID.recordName)?
            .toProfile(zoneID: resolvedZoneID) else { return }
        let (totalXP, _) = xpService.calculatedXP(baseXP: remaining, profile: heroProfile)
        let rewardID = RewardEvent.recordID(completionRecordName: log.id.recordName, zoneID: resolvedZoneID)
        // WHY day count wins: legacy rows keep stale targetCount after template gains days.
        let templatesByID = SpecificDaysHelper.templatesByID(cache: cacheService, familyName: quest.family.recordID.recordName, zoneID: quest.id.zoneID)
        let effectiveTarget = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
        let rewardEvent = RewardEvent(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            questCompletion: CKRecord.Reference(recordID: log.id, action: .none),
            xpAmount: totalXP,
            goldAmount: GoldCalculation.creditPennies(for: quest, approvedCount: approvedCount, effectiveTarget: effectiveTarget),
            timestamp: log.completedDate,
            family: log.family,
            id: rewardID
        )
        await cacheService.upsertRewardEvent(rewardEvent)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: rewardID,
            appState: appState,
            logger: logger,
            context: "QuestCompletionService.completeQuest.autoApproved.transient.reward"
        )
        do {
            _ = try await xpService.addXP(totalXP, to: profile)
        } catch {
            logger.warning("QuestCompletionService.completeQuest autoApproved transient XP award failed: \(error, privacy: .private)")
        }
        var stamped = log
        stamped.xpCredited = remaining
        await cacheService.upsertQuestCompletion(stamped)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: stamped.id,
            appState: appState,
            logger: logger,
            context: "QuestCompletionService.completeQuest.autoApproved.transient.stamp"
        )
        if let cached = cacheService.fetchQuestCompletion(recordName: log.id.recordName, family: quest.family.recordID.recordName) {
            log = cached.toQuestCompletion(zoneID: resolvedZoneID)
        }
    }

    private func handleAutoApproveHardRollback(
        log: QuestCompletion,
        quest: Quest,
        profile: Profile,
        resolvedZoneID: CKRecordZone.ID,
        baselineXP: Int,
        awardApplied: Bool,
        awardedXPCredited: Int?,
        error _: Error
    ) async throws {
        let rewardID = RewardEvent.recordID(completionRecordName: log.id.recordName, zoneID: resolvedZoneID)
        // WHY single step: tombstone capture survives row removal across the await.
        await ActiveFamilyScopeGuard.deleteAndEnqueue(
            cacheService: cacheService,
            target: .init(recordID: log.id, familyRecordName: quest.family.recordID.recordName),
            type: .questCompletion,
            deleteContext: .init(
                coordinator: syncCoordinator,
                appState: appState,
                logger: logger,
                context: "QuestCompletionService.rollbackDelete.completion",
                expectedActiveZone: appState.familyZoneID
            )
        )
        await ActiveFamilyScopeGuard.deleteAndEnqueue(
            cacheService: cacheService,
            target: .init(recordID: rewardID, familyRecordName: quest.family.recordID.recordName),
            type: .rewardEvent,
            deleteContext: .init(
                coordinator: syncCoordinator,
                appState: appState,
                logger: logger,
                context: "QuestCompletionService.rollbackDelete.reward",
                expectedActiveZone: appState.familyZoneID
            )
        )
        if awardApplied || awardedXPCredited != nil {
            await revertProfileXPToBaseline(profile: profile, resolvedZoneID: resolvedZoneID, baselineXP: baselineXP)
            await revertQuestBankAfterAward(quest: quest, resolvedZoneID: resolvedZoneID, credited: awardedXPCredited)
        } else if let cached = cacheService.fetchProfile(recordName: profile.id.recordName, family: quest.family.recordID.recordName),
                  cached.xpTotal != baselineXP
        {
            var reverted = cached.toProfile(zoneID: resolvedZoneID)
            reverted.xp = baselineXP
            reverted.level = XPService.level(forXP: baselineXP)
            await cacheService.upsertProfile(reverted)
            if appState.currentProfile?.id.recordName == reverted.id.recordName {
                appState.currentProfile = reverted
            }
            ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
                syncCoordinator,
                id: reverted.id,
                appState: appState,
                logger: logger,
                context: "QuestCompletionService.rollbackXP.hard"
            )
        }
    }

    private func revertProfileXPToBaseline(profile: Profile, resolvedZoneID: CKRecordZone.ID, baselineXP: Int) async {
        guard let cached = cacheService.fetchProfile(recordName: profile.id.recordName, family: profile.family.recordID.recordName) else { return }
        var reverted = cached.toProfile(zoneID: resolvedZoneID)
        guard reverted.xp != baselineXP else { return }
        reverted.xp = baselineXP
        reverted.level = XPService.level(forXP: baselineXP)
        await cacheService.upsertProfile(reverted)
        if appState.currentProfile?.id.recordName == reverted.id.recordName {
            appState.currentProfile = reverted
        }
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: reverted.id,
            appState: appState,
            logger: logger,
            context: "QuestCompletionService.rollbackXP"
        )
    }

    private func revertQuestBankAfterAward(quest: Quest, resolvedZoneID: CKRecordZone.ID, credited: Int?) async {
        guard let credited else { return }
        guard let cachedQuest = cacheService.fetchQuest(recordName: quest.id.recordName, family: quest.family.recordID.recordName) else { return }
        var revertedQuest = cachedQuest.toQuest(zoneID: resolvedZoneID)
        revertedQuest.xpBanked = max(0, revertedQuest.xpBanked - credited)
        await cacheService.upsertQuest(revertedQuest)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: revertedQuest.id,
            appState: appState,
            logger: logger,
            context: "QuestCompletionService.rollbackQuestXP"
        )
    }

    private func completeParentVerify(log: QuestCompletion, quest: Quest, isFinalSubPart: Bool, resolvedZoneID _: CKRecordZone.ID)
        async throws -> QuestCompletion
    {
        var mutableLog = log
        mutableLog.verificationStatus = .pending
        await cacheService.upsertQuestCompletion(mutableLog)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: mutableLog.id,
            appState: appState,
            logger: logger,
            context: isFinalSubPart ? "QuestCompletionService.completeQuest" : "QuestCompletionService.completeQuest.intermediate"
        )
        dispatchParentReviewNotification(for: mutableLog, quest: quest)
        Task { [weak self] in await self?.syncCoordinator.sendPendingChanges() }
        return mutableLog
    }

    func withdrawCompletion(questLog: QuestCompletion, by profile: Profile) async throws {
        guard let acting = appState.currentProfile,
              acting.id == profile.id || acting.role.isParent
        else {
            logger.warning("withdrawCompletion aborted: unauthorized actor for log \(questLog.id.recordName, privacy: .private)")
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRef: questLog.family,
            zoneID: questLog.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )
        let logName = questLog.id.recordName
        let insertedWithdrawal = inFlightWithdrawals.withLock { $0.insert(logName).inserted }
        guard insertedWithdrawal else {
            throw QuestServiceError.alreadyInFlight
        }
        defer { inFlightWithdrawals.withLock { _ = $0.remove(logName) } }

        try validateCanWithdrawCompletion(questLog, logName: logName)

        var updated = questLog
        if let cached = cacheService.fetchQuestCompletion(recordName: logName, family: questLog.family.recordID.recordName) {
            updated = cached.toQuestCompletion(zoneID: questLog.id.zoneID)
        }
        updated.verificationStatus = .withdrawn
        await cacheService.upsertQuestCompletion(updated)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: updated.id, appState: appState, logger: logger, context: "QuestCompletionService.withdrawCompletion")
        Task { [weak self] in await self?.syncCoordinator.sendPendingChanges() }
    }

    func withdrawCompletion(questLog: QuestCompletionCache, by profile: Profile) async throws {
        guard let zoneID = appState.familyZoneID else {
            logger.warning("withdrawCompletion aborted: no active family zone")
            throw FamilyServiceError.unauthorized
        }
        try await withdrawCompletion(questLog: questLog.toQuestCompletion(zoneID: zoneID), by: profile)
    }

    // MARK: - Validation Helpers

    private func validateCanCompleteQuest(_ quest: Quest, questName: String) async throws {
        if let cachedQuest = cacheService.fetchQuest(recordName: questName, family: quest.family.recordID.recordName) {
            guard cachedQuest.isActive else {
                throw QuestServiceError.alreadyCompleted
            }
            if let expectedTag = quest.changeTag, let currentTag = cachedQuest.changeTag,
               expectedTag != currentTag
            {
                throw QuestServiceError.staleData("quest was updated on another device")
            }
        }
        // Local validation against cached completions to prevent double completion.
        let logs = cachedQuestLogs(forQuest: quest)
        let nonRejectedCount = logs.filter(\.verificationStatus.countsTowardCompletion).count
        // WHY day count wins: legacy rows keep stale targetCount after template gains days.
        let templatesByID = SpecificDaysHelper.templatesByID(cache: cacheService, familyName: quest.family.recordID.recordName, zoneID: quest.id.zoneID)
        let effectiveTarget = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
        if GoldCalculation.nonRejectedLogsReachTarget(quest: quest, nonRejectedCount: nonRejectedCount, effectiveTarget: effectiveTarget) {
            throw QuestServiceError.alreadyCompleted
        }
        if quest.approvalMode == .parentVerify, logs.contains(where: { $0.verificationStatus == .pending }) {
            toastManager?.show(message: "The previous completion is awaiting parent verification.", type: .info)
            throw QuestServiceError.alreadyInFlight
        }
    }

    func validateCanTransitionCompletion(_ questLog: QuestCompletion, logName: String) throws {
        if let cached = cacheService.fetchQuestCompletion(recordName: logName, family: questLog.family.recordID.recordName) {
            guard cached.verificationStatusEnum == .pending else {
                throw QuestServiceError.alreadyResolved(cached.verificationStatus)
            }
            if let expectedTag = questLog.changeTag, let currentTag = cached.changeTag, expectedTag != currentTag {
                throw QuestServiceError.staleData("completion was updated on another device")
            }
        } else {
            guard questLog.verificationStatus == .pending else {
                throw QuestServiceError.alreadyResolved(questLog.verificationStatus.rawValue)
            }
        }
    }

    private func validateCanWithdrawCompletion(_ questLog: QuestCompletion, logName: String) throws {
        if let cached = cacheService.fetchQuestCompletion(recordName: logName, family: questLog.family.recordID.recordName) {
            guard cached.verificationStatusEnum == .pending || cached.verificationStatusEnum == .autoApproved else {
                throw QuestServiceError.alreadyResolved(cached.verificationStatus)
            }
            if let expectedTag = questLog.changeTag, let currentTag = cached.changeTag, expectedTag != currentTag {
                throw QuestServiceError.staleData("completion was updated on another device")
            }
        } else {
            guard questLog.verificationStatus == .pending || questLog.verificationStatus == .autoApproved else {
                throw QuestServiceError.alreadyResolved(questLog.verificationStatus.rawValue)
            }
        }
    }
}
