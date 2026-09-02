//
//  QuestService+Completions.swift
//  LootList
//
//  Created by Ben Mackin on 8/1/26.
//

import CloudKit
import Foundation
import os
import Synchronization

// MARK: - Quest Completions & Verification

extension QuestService {
    private var logger: Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService")
    }

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
        guard let acting = appState.currentProfile,
              acting.id == profile.id
        else {
            logger.warning("markComplete aborted: acting profile mismatch for quest \(quest.id.recordName, privacy: .private)")
            throw FamilyServiceError.unauthorized
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
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRef: quest.family,
            zoneID: quest.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )
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
        let isFinalSubPart = priorCount + 1 >= quest.targetCount

        switch quest.approvalMode {
        case .autoApprove:
            log = try await completeAutoApprove(log: log, quest: quest, profile: profile, resolvedZoneID: resolvedZoneID)
        case .parentVerify:
            log = try await completeParentVerify(log: log, quest: quest, isFinalSubPart: isFinalSubPart, resolvedZoneID: resolvedZoneID)
        }
        Task { await syncCoordinator.sendPendingChanges() }
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
            context: "QuestService.completeQuest.autoApproved"
        )
        let baselineXP = cacheService.fetchProfile(recordName: profile.id.recordName, family: quest.family.recordID.recordName)?
            .xpTotal ?? profile.xp
        var awardApplied = false
        var awardedXPCredited: Int?
        do {
            _ = try await applyReward(for: quest, to: profile, completion: mutableLog)
            if let cached = cacheService.fetchQuestCompletion(recordName: mutableLog.id.recordName, family: quest.family.recordID.recordName) {
                mutableLog = cached.toQuestCompletion(zoneID: resolvedZoneID)
                awardedXPCredited = cached.xpCredited
                awardApplied = true
            }
        } catch {
            if isTransientCompletionError(error) {
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
            context: "QuestService.completeQuest.autoApproved.transient"
        )
        if cacheService.fetchQuestCompletion(recordName: mutableLog.id.recordName, family: quest.family.recordID.recordName)?.xpCredited == nil {
            try await applyTransientFallbackCredit(log: &mutableLog, quest: quest, profile: profile, resolvedZoneID: resolvedZoneID)
        }
        toastManager?.show(message: "Quest completion queued — will sync when online.", type: .info)
        Task { await syncCoordinator.sendPendingChanges() }
        return mutableLog
    }

    private func applyTransientFallbackCredit(log: inout QuestCompletion, quest: Quest, profile: Profile, resolvedZoneID: CKRecordZone.ID)
        async throws
    {
        let logs: [QuestCompletion]
        do {
            logs = try await fetchQuestLogs(forQuest: quest, useCache: true)
        } catch {
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
                context: "QuestService.completeQuest.autoApproved.transient.stampZero"
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
        let rewardEvent = RewardEvent(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            questCompletion: CKRecord.Reference(recordID: log.id, action: .none),
            xpAmount: totalXP,
            goldAmount: GoldCalculation.creditAsDouble(for: quest, approvedCount: approvedCount),
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
            context: "QuestService.completeQuest.autoApproved.transient.reward"
        )
        do { _ = try await xpService.addXP(totalXP, to: profile) } catch {}
        var stamped = log
        stamped.xpCredited = remaining
        await cacheService.upsertQuestCompletion(stamped)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: stamped.id,
            appState: appState,
            logger: logger,
            context: "QuestService.completeQuest.autoApproved.transient.stamp"
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
        let rewardRecordName = "reward-\(log.id.recordName)"
        await cacheService.invalidate(recordName: log.id.recordName, family: quest.family.recordID.recordName, type: .questCompletion)
        await cacheService.invalidate(recordName: rewardRecordName, family: quest.family.recordID.recordName, type: .rewardEvent)
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
                context: "QuestService.rollbackXP.hard"
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
            context: "QuestService.rollbackXP"
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
            context: "QuestService.rollbackQuestXP"
        )
    }

    private func completeParentVerify(log: QuestCompletion, quest: Quest, isFinalSubPart: Bool, resolvedZoneID: CKRecordZone.ID)
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
            context: isFinalSubPart ? "QuestService.completeQuest" : "QuestService.completeQuest.intermediate"
        )
        do {
            _ = try await cloudKit.save(mutableLog, in: resolvedZoneID)
        } catch {
            if isTransientCompletionError(error) {
                ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
                    syncCoordinator,
                    id: mutableLog.id,
                    appState: appState,
                    logger: logger,
                    context: "QuestService.completeQuest.pending.transient"
                )
                toastManager?.show(message: "Quest completion queued — will sync when online.", type: .info)
                dispatchParentReviewNotification(for: mutableLog, quest: quest)
                Task { await syncCoordinator.sendPendingChanges() }
                return mutableLog
            }
            await cacheService.invalidate(recordName: mutableLog.id.recordName, family: quest.family.recordID.recordName, type: .questCompletion)
            throw error
        }
        dispatchParentReviewNotification(for: mutableLog, quest: quest)
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
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: updated.id, appState: appState, logger: logger, context: "QuestService.withdrawCompletion")
        Task {
            await syncCoordinator.sendPendingChanges()
        }
    }

    func withdrawCompletion(questLog: QuestCompletionCache, by profile: Profile) async throws {
        guard let zoneID = appState.familyZoneID else {
            logger.warning("withdrawCompletion aborted: no active family zone")
            throw FamilyServiceError.unauthorized
        }
        try await withdrawCompletion(questLog: questLog.toQuestCompletion(zoneID: zoneID), by: profile)
    }

    // MARK: - Parent Review

    @discardableResult
    func verify(questLog: QuestCompletion, by parent: Profile) async throws -> QuestCompletion {
        guard let acting = appState.currentProfile,
              acting.id == parent.id,
              acting.role.isParent
        else {
            logger.warning("verify aborted: acting profile not parent for log \(questLog.id.recordName, privacy: .private)")
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRef: questLog.family,
            zoneID: questLog.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )
        let logName = questLog.id.recordName
        let insertedVerify = inFlightVerifications.withLock { $0.insert(logName).inserted }
        guard insertedVerify else {
            throw QuestServiceError.alreadyInFlight
        }
        defer { inFlightVerifications.withLock { _ = $0.remove(logName) } }

        try validateCanTransitionCompletion(questLog, logName: logName)

        var updated = questLog
        if let cached = cacheService.fetchQuestCompletion(recordName: logName, family: questLog.family.recordID.recordName) {
            updated = cached.toQuestCompletion(zoneID: questLog.id.zoneID)
        }
        updated.verificationStatus = .verified
        updated.verifiedBy = CKRecord.Reference(recordID: parent.id, action: .none)
        updated.verifiedDate = Date()

        // Persists verification decision locally first; enqueues engine save for CloudKit.
        await cacheService.upsertQuestCompletion(updated)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: updated.id, appState: appState, logger: logger, context: "QuestService.verify")

        try await handlePostVerifySettlement(questLog: questLog, updated: updated)

        // Adopt whatever the settlement step stamped onto the cached row.
        if let cached = cacheService.fetchQuestCompletion(recordName: logName, family: questLog.family.recordID.recordName) {
            updated = cached.toQuestCompletion(zoneID: questLog.id.zoneID)
        }

        return updated
    }

    @discardableResult
    func approve(questLog: QuestCompletion, by parent: Profile) async throws -> QuestCompletion {
        try await verify(questLog: questLog, by: parent)
    }

    @discardableResult
    func reject(questLog: QuestCompletion, by parent: Profile) async throws -> QuestCompletion {
        guard let acting = appState.currentProfile,
              acting.id == parent.id,
              acting.role.isParent
        else {
            logger.warning("reject aborted: acting profile not parent for log \(questLog.id.recordName, privacy: .private)")
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRef: questLog.family,
            zoneID: questLog.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )
        let logName = questLog.id.recordName
        let insertedReject = inFlightVerifications.withLock { $0.insert(logName).inserted }
        guard insertedReject else {
            throw QuestServiceError.alreadyInFlight
        }
        defer { inFlightVerifications.withLock { _ = $0.remove(logName) } }

        try validateCanTransitionCompletion(questLog, logName: logName)

        var updated = questLog
        if let cached = cacheService.fetchQuestCompletion(recordName: logName, family: questLog.family.recordID.recordName) {
            updated = cached.toQuestCompletion(zoneID: questLog.id.zoneID)
        }
        updated.verificationStatus = .rejected
        updated.verifiedBy = CKRecord.Reference(recordID: parent.id, action: .none)
        updated.verifiedDate = Date()

        await cacheService.upsertQuestCompletion(updated)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: updated.id, appState: appState, logger: logger, context: "QuestService.reject")

        dispatchRejectionNotification(for: updated)
        return updated
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
        if GoldCalculation.nonRejectedLogsReachTarget(quest: quest, nonRejectedCount: nonRejectedCount) {
            throw QuestServiceError.alreadyCompleted
        }
        if quest.approvalMode == .parentVerify, logs.contains(where: { $0.verificationStatus == .pending }) {
            toastManager?.show(message: "The previous completion is awaiting parent verification.", type: .info)
            throw QuestServiceError.alreadyInFlight
        }
    }

    private func validateCanTransitionCompletion(_ questLog: QuestCompletion, logName: String) throws {
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

    // MARK: - Post-Transition Notification & Settlement Helpers

    private func dispatchParentReviewNotification(for log: QuestCompletion, quest: Quest) {
        guard let currentProfile = appState.currentProfile, currentProfile.role.isParent else { return }
        let completerRecordName = log.completedBy.recordID.recordName
        guard currentProfile.id.recordName != completerRecordName else { return }
        let familyName = quest.family.recordID.recordName
        if let parent = resolveParent(recordID: quest.createdBy.recordID, familyRecordName: familyName) {
            guard parent.role.isParent else { return }
            guard parent.id.recordName != completerRecordName else { return }
            if let notificationService {
                Task { @MainActor @Sendable [logger, notificationService, log, parent] in
                    do {
                        try await notificationService.sendQuestNeedsReview(questLog: log, to: parent)
                    } catch {
                        logger.error("Failed to send quest review notification: \(error, privacy: .private)")
                    }
                }
            }
            return
        }
        if let parent = resolveParentViaCacheScan(familyRecordName: familyName),
           let notificationService
        {
            guard parent.role.isParent else { return }
            guard parent.id.recordName != completerRecordName else { return }
            Task { @MainActor @Sendable [logger, notificationService, log, parent] in
                do {
                    try await notificationService.sendQuestNeedsReview(questLog: log, to: parent)
                } catch {
                    logger.error("Failed to send quest review notification via scan: \(error, privacy: .private)")
                }
            }
            return
        }
        logger.info("Parent profile not cached; skipping review notification — cache will sync via CKSyncEngine")
    }

    private func dispatchRejectionNotification(for updated: QuestCompletion) {
        if let hero = resolveHero(for: updated) {
            if let notificationService {
                Task { @MainActor @Sendable [logger, notificationService, updated, hero] in
                    do {
                        try await notificationService.sendQuestRejected(questLog: updated, to: hero)
                    } catch {
                        logger.error("Failed to send quest rejection notification: \(error, privacy: .private)")
                    }
                }
            }
            return
        }
        if let hero = resolveHeroViaCacheScan(for: updated),
           let notificationService
        {
            Task { @MainActor @Sendable [logger, notificationService, updated, hero] in
                do {
                    try await notificationService.sendQuestRejected(questLog: updated, to: hero)
                } catch {
                    logger.error("Failed to send quest rejection notification via scan: \(error, privacy: .private)")
                }
            }
            return
        }
        logger.info("Hero profile not cached during reject; skipping rejection notification — cache will sync via CKSyncEngine")
    }

    private func handlePostVerifySettlement(questLog: QuestCompletion, updated: QuestCompletion) async throws {
        let quest: Quest
        let hero: Profile

        if let cachedQuest = resolveQuest(for: questLog),
           let cachedHero = resolveHero(for: questLog)
        {
            quest = cachedQuest
            hero = cachedHero
        } else if let cachedQuest = resolveQuest(for: questLog),
                  let scannedHero = resolveHeroViaCacheScan(for: questLog)
        {
            quest = cachedQuest
            hero = scannedHero
        } else if let scannedQuest = resolveQuestViaCacheScan(for: questLog),
                  let cachedHero = resolveHero(for: questLog)
        {
            quest = scannedQuest
            hero = cachedHero
        } else if let scannedQuest = resolveQuestViaCacheScan(for: questLog),
                  let scannedHero = resolveHeroViaCacheScan(for: questLog)
        {
            quest = scannedQuest
            hero = scannedHero
        } else {
            logger.warning("Cache miss during verify for quest/hero; skipping reward settlement — cache will sync via CKSyncEngine")
            toastManager?.show(message: "Syncing latest quest data. Please try again.", type: .info)
            Task {
                await syncCoordinator.fetchChanges()
            }
            throw QuestServiceError.missingRecord(questLog.quest.recordID.recordName)
        }

        let creditedGold = try await applyReward(for: quest, to: hero, completion: updated)

        if let achievementService, let family = appState.family {
            let achService = achievementService
            Task {
                do {
                    _ = try await achService.evaluateAll(for: hero, family: family)
                } catch {
                    logger.warning("Failed to evaluate achievements after quest verification: \(error, privacy: .private)")
                }
            }
        }

        if let notificationService {
            let goldText = CurrencyFormatter.string(creditedGold)
            Task { @MainActor @Sendable [logger, notificationService, hero, goldText] in
                do {
                    try await notificationService.send(
                        .questCompleted,
                        to: hero,
                        title: "🏆 Quest Verified!",
                        body: "Your quest was verified! You earned \(goldText)."
                    )
                } catch {
                    logger.error("Failed to send quest completion notification: \(error, privacy: .private)")
                }
            }
        }
    }

    private func resolveParent(recordID: CKRecord.ID, familyRecordName: String) -> Profile? {
        if let cached = cacheService.fetchProfile(recordName: recordID.recordName, family: familyRecordName) {
            return cached.toProfile(zoneID: recordID.zoneID)
        }
        return nil
    }

    /// Cache-first quest resolution for the reward step of `verify`.
    private func resolveQuest(for questLog: QuestCompletion) -> Quest? {
        let questID = questLog.quest.recordID
        let familyName = questLog.family.recordID.recordName
        if let cached = cacheService.fetchQuest(recordName: questID.recordName, family: familyName) {
            return cached.toQuest(zoneID: questID.zoneID)
        }
        return nil
    }

    /// Cache-first hero (completer) resolution for the reward step of `verify`.
    private func resolveHero(for questLog: QuestCompletion) -> Profile? {
        let heroID = questLog.completedBy.recordID
        let familyName = questLog.family.recordID.recordName
        if let cached = cacheService.fetchProfile(recordName: heroID.recordName, family: familyName) {
            return cached.toProfile(zoneID: heroID.zoneID)
        }
        return nil
    }

    private func resolveParentViaCacheScan(familyRecordName: String) -> Profile? {
        let cache = cacheService
        let candidates = cache.fetchProfiles(family: familyRecordName)
            .filter { $0.roleEnum?.isParent == true }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        guard let match = candidates.first else { return nil }
        let zoneID = CKRecordZone.ID(
            zoneName: match.sourceZoneName ?? familyRecordName,
            ownerName: match.sourceZoneOwnerName ?? CKCurrentUserDefaultName
        )
        return match.toProfile(zoneID: zoneID)
    }

    private func resolveHeroViaCacheScan(for questLog: QuestCompletion) -> Profile? {
        let cache = cacheService
        let familyName = questLog.family.recordID.recordName
        let heroID = questLog.completedBy.recordID
        if let exact = cache.fetchProfiles(family: familyName).first(where: { $0.recordName == heroID.recordName }) {
            return exact.toProfile(zoneID: heroID.zoneID)
        }
        guard let match = cache.fetchProfiles(family: familyName).first(where: { $0.roleEnum == .hero }) else { return nil }
        let zoneID = CKRecordZone.ID(
            zoneName: match.sourceZoneName ?? familyName,
            ownerName: match.sourceZoneOwnerName ?? CKCurrentUserDefaultName
        )
        return match.toProfile(zoneID: zoneID)
    }

    private func resolveQuestViaCacheScan(for questLog: QuestCompletion) -> Quest? {
        let cache = cacheService
        let questID = questLog.quest.recordID
        let familyName = questLog.family.recordID.recordName
        if let exact = cache.fetchQuest(recordName: questID.recordName, family: familyName) {
            return exact.toQuest(zoneID: questID.zoneID)
        }
        return cache.fetchQuests(family: familyName).first?.toQuest(zoneID: questID.zoneID)
    }

    /// Strictly-local cached logs for a quest, sorted newest-first.
    func cachedQuestLogs(forQuest quest: Quest) -> [QuestCompletion] {
        let cache = cacheService
        let questName = quest.id.recordName
        return cache.fetchQuestCompletions(family: quest.family.recordID.recordName)
            .filter { $0.questRecordName == questName }
            .map { $0.toQuestCompletion(zoneID: quest.id.zoneID) }
            .sorted { $0.completedDate > $1.completedDate }
    }

    // WHY: transient CloudKit errors must keep optimistic completion + XP and queue via CKSyncEngine; hard errors roll back.
    private func isTransientCompletionError(_ error: Error) -> Bool {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy, .resultsTruncated:
                return true
            case .operationCancelled:
                if let underlying = ckError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSURLErrorDomain, underlying.code == NSURLErrorTimedOut {
                    return true
                }
                return false
            default:
                if let underlying = ckError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSURLErrorDomain, underlying.code == NSURLErrorTimedOut {
                    return true
                }
                // Also treat timeout-wrapped errors.
                if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorTimedOut {
                    return true
                }
                return false
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
            return true
        }
        if let serviceError = error as? CloudKitServiceError {
            switch serviceError {
            case .networkUnavailable, .retryable, .exhaustedBudget:
                return true
            case .zoneNotFound, .notFound, .serverRecordChanged, .changeTokenExpired, .invalidArguments, .accountUnavailable, .shareFailed, .shareAcceptFailed,
                 .paginationExhausted,
                 .underlying, .zoneSetupFailed:
                return false
            }
        }
        // Non-CKError (validation, permission, unknownItem path) is hard per spec.
        if error is CKError {
            return false
        }
        // Any CKError partialFailure or permission errors are hard — already covered by default false.
        return false
    }
}
