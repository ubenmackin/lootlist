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

    private func resolvedIsOwner() -> Bool {
        ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
    }

    /// Resolved owner scope for sync enqueues, logging when it diverges from the stored flag.
    /// WHY: Hero completions must ride .shared; owner check uses Family.creatorUserRecordName anchor, not role.
    private func correctedIsOwnerForSync() -> Bool {
        let isOwner = resolvedIsOwner()
        // Hoisted local: Swift 6 requires explicit capture semantics for
        // self-referencing property access inside the logger interpolation.
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("markComplete isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
        return isOwner
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

        // WHY: Active family zone is sole authority — hero completions target shared zone; diverged IDs corrected to active zone.
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
        if quest.approvalMode == .autoApprove {
            log.verificationStatus = .autoApproved
            try await applyReward(for: quest, to: profile, completion: log)
            if let cached = cacheService.fetchQuestCompletion(recordName: log.id.recordName, family: quest.family.recordID.recordName) {
                log = cached.toQuestCompletion(zoneID: resolvedZoneID)
            } else {
                // Persist the completion even when the reward claim was lost
                // (applyReward returned early), so the @Query-driven UI reflects
                // it and validateCanCompleteQuest prevents duplicates.
                await cacheService.upsertQuestCompletion(log)
                ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
                    syncCoordinator,
                    id: log.id,
                    appState: appState,
                    logger: logger,
                    context: "QuestService.completeQuest.autoApproved"
                )
            }
        } else {
            await cacheService.upsertQuestCompletion(log)
            ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: log.id, appState: appState, logger: logger, context: "QuestService.completeQuest")
        }

        if quest.approvalMode == .parentVerify {
            dispatchParentReviewNotification(for: log, quest: quest)
        }
        Task {
            await syncCoordinator.sendPendingChanges()
        }
        return log
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

        try validateCanTransitionCompletion(questLog, logName: logName)

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
            if let expectedTag = quest.changeTag, let currentTag = cachedQuest.changeTag, expectedTag != currentTag {
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

    // MARK: - Post-Transition Notification & Settlement Helpers

    private func dispatchParentReviewNotification(for log: QuestCompletion, quest: Quest) {
        // WHY: questNeedsReview is parent-only — never enqueue local notification on child's device; sync ingestion delivers to parent.
        guard let currentProfile = appState.currentProfile, currentProfile.role.isParent else { return }
        // WHY: shared-device edge — avoid self-notification when completer and current profile are the same.
        let completerRecordName = log.completedBy.recordID.recordName
        guard currentProfile.id.recordName != completerRecordName else { return }
        let familyName = quest.family.recordID.recordName
        if let parent = resolveParent(recordID: quest.createdBy.recordID, familyRecordName: familyName) {
            // WHY: questNeedsReview is parent-only — verify resolved profile is actually a parent.
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
            // WHY: questNeedsReview is parent-only — fallback scan must still resolve a parent.
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
}
