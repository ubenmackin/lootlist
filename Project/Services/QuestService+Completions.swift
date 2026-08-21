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
    func markComplete(quest: Quest, by profile: Profile, at completedDate: Date = Date()) async throws -> QuestCompletion {
        guard let appState, let acting = appState.currentProfile,
              acting.id == profile.id
        else {
            throw FamilyServiceError.unauthorized
        }
        guard profile.family.recordID == quest.family.recordID,
              profile.id.zoneID == quest.id.zoneID
        else {
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

        var log = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: CKRecord.Reference(recordID: profile.id, action: .none),
            approvalMode: quest.approvalMode,
            weekOf: quest.weekOf,
            family: quest.family,
            id: CKRecord.ID(recordName: UUID().uuidString, zoneID: quest.id.zoneID)
        )
        log.completedDate = completedDate
        if quest.approvalMode == .autoApprove {
            log.verificationStatus = .autoApproved
            try await applyReward(for: quest, to: profile, completion: log)
            if let cached = cacheService?.fetchQuestCompletion(recordName: log.id.recordName, family: quest.family.recordID.recordName) {
                log = cached.toQuestCompletion(zoneID: quest.id.zoneID)
            } else {
                // Persist the completion even when the reward claim was lost
                // (applyReward returned early), so the @Query-driven UI reflects
                // it and validateCanCompleteQuest prevents duplicates.
                cacheService?.upsertQuestCompletion(log)
                let isOwner = appState.isZoneOwner
                syncCoordinator?.enqueueSave(recordID: log.id, isOwner: isOwner)
            }
        } else {
            cacheService?.upsertQuestCompletion(log)
            let isOwner = appState.isZoneOwner
            syncCoordinator?.enqueueSave(recordID: log.id, isOwner: isOwner)
        }

        if quest.approvalMode == .parentVerify {
            dispatchParentReviewNotification(for: log, quest: quest)
        }
        return log
    }

    func withdrawCompletion(questLog: QuestCompletion, by profile: Profile) async throws {
        guard let appState, let acting = appState.currentProfile,
              acting.id == profile.id || acting.role.isParent
        else {
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
        if let cached = cacheService?.fetchQuestCompletion(recordName: logName, family: questLog.family.recordID.recordName) {
            updated = cached.toQuestCompletion(zoneID: questLog.id.zoneID)
        }
        updated.verificationStatus = .withdrawn

        cacheService?.upsertQuestCompletion(updated)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
    }

    @discardableResult
    func verify(questLog: QuestCompletion, by parent: Profile) async throws -> QuestCompletion {
        guard let appState, let acting = appState.currentProfile,
              acting.id == parent.id,
              acting.role.isParent
        else {
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
        if let cached = cacheService?.fetchQuestCompletion(recordName: logName, family: questLog.family.recordID.recordName) {
            updated = cached.toQuestCompletion(zoneID: questLog.id.zoneID)
        }
        updated.verificationStatus = .verified
        updated.verifiedBy = CKRecord.Reference(recordID: parent.id, action: .none)
        updated.verifiedDate = Date()

        try await handlePostVerifySettlement(questLog: questLog, updated: updated)

        if let cached = cacheService?.fetchQuestCompletion(recordName: logName, family: questLog.family.recordID.recordName) {
            updated = cached.toQuestCompletion(zoneID: questLog.id.zoneID)
        } else {
            cacheService?.upsertQuestCompletion(updated)
            let isOwner = appState.isZoneOwner
            syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
        }

        return updated
    }

    @discardableResult
    func reject(questLog: QuestCompletion, by parent: Profile) async throws -> QuestCompletion {
        guard let appState, let acting = appState.currentProfile,
              acting.id == parent.id,
              acting.role.isParent
        else {
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
        if let cached = cacheService?.fetchQuestCompletion(recordName: logName, family: questLog.family.recordID.recordName) {
            updated = cached.toQuestCompletion(zoneID: questLog.id.zoneID)
        }
        updated.verificationStatus = .rejected
        updated.verifiedBy = CKRecord.Reference(recordID: parent.id, action: .none)
        updated.verifiedDate = Date()

        cacheService?.upsertQuestCompletion(updated)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)

        dispatchRejectionNotification(for: updated)
        return updated
    }

    // MARK: - Validation Helpers

    private func validateCanCompleteQuest(_ quest: Quest, questName: String) async throws {
        if let cachedQuest = cacheService?.fetchQuest(recordName: questName, family: quest.family.recordID.recordName) {
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
        if let cached = cacheService?.fetchQuestCompletion(recordName: logName, family: questLog.family.recordID.recordName) {
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
        let familyName = quest.family.recordID.recordName
        if let parent = resolveParent(recordID: quest.createdBy.recordID, familyRecordName: familyName) {
            if let notificationService {
                Task { @Sendable [logger] in
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
            Task { @Sendable [logger] in
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
                Task { @Sendable [logger] in
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
            Task { @Sendable [logger] in
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
            throw QuestServiceError.missingRecord(questLog.quest.recordID.recordName)
        }

        let creditedGold = try await applyReward(for: quest, to: hero, completion: updated)

        if let achievementService, let family = appState?.family {
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
            Task { @Sendable [logger] in
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
        if let cached = cacheService?.fetchProfile(recordName: recordID.recordName, family: familyRecordName) {
            return cached.toProfile(zoneID: recordID.zoneID)
        }
        return nil
    }

    /// Cache-first quest resolution for the reward step of `verify`.
    private func resolveQuest(for questLog: QuestCompletion) -> Quest? {
        let questID = questLog.quest.recordID
        let familyName = questLog.family.recordID.recordName
        if let cached = cacheService?.fetchQuest(recordName: questID.recordName, family: familyName) {
            return cached.toQuest(zoneID: questID.zoneID)
        }
        return nil
    }

    /// Cache-first hero (completer) resolution for the reward step of `verify`.
    private func resolveHero(for questLog: QuestCompletion) -> Profile? {
        let heroID = questLog.completedBy.recordID
        let familyName = questLog.family.recordID.recordName
        if let cached = cacheService?.fetchProfile(recordName: heroID.recordName, family: familyName) {
            return cached.toProfile(zoneID: heroID.zoneID)
        }
        return nil
    }

    private func resolveParentViaCacheScan(familyRecordName: String) -> Profile? {
        guard let cache = cacheService else { return nil }
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
        guard let cache = cacheService else { return nil }
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
        guard let cache = cacheService else { return nil }
        let questID = questLog.quest.recordID
        let familyName = questLog.family.recordID.recordName
        if let exact = cache.fetchQuest(recordName: questID.recordName, family: familyName) {
            return exact.toQuest(zoneID: questID.zoneID)
        }
        return cache.fetchQuests(family: familyName).first?.toQuest(zoneID: questID.zoneID)
    }

    /// Strictly-local cached logs for a quest, sorted newest-first.
    func cachedQuestLogs(forQuest quest: Quest) -> [QuestCompletion] {
        guard let cache = cacheService else { return [] }
        let questName = quest.id.recordName
        return cache.fetchQuestCompletions(family: quest.family.recordID.recordName)
            .filter { $0.questRecordName == questName }
            .map { $0.toQuestCompletion(zoneID: quest.id.zoneID) }
            .sorted { $0.completedDate > $1.completedDate }
    }
}
