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
        if inFlightCompletions.withLock({ $0.contains(questName) }) {
            toastManager?.show(message: "This quest is already being completed.", type: .info)
            throw QuestServiceError.alreadyInFlight
        }
        inFlightCompletions.withLock { _ = $0.insert(questName) }
        defer { inFlightCompletions.withLock { _ = $0.remove(questName) } }

        try validateCanCompleteQuest(quest, questName: questName)

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
        let alreadyInFlight = inFlightWithdrawals.withLock { $0.contains(logName) }
        if alreadyInFlight {
            throw QuestServiceError.alreadyInFlight
        }
        inFlightWithdrawals.withLock { _ = $0.insert(logName) }
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
        let alreadyInFlight = inFlightVerifications.withLock { $0.contains(logName) }
        if alreadyInFlight {
            throw QuestServiceError.alreadyInFlight
        }
        inFlightVerifications.withLock { _ = $0.insert(logName) }
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
        let alreadyInFlight = inFlightVerifications.withLock { $0.contains(logName) }
        if alreadyInFlight {
            throw QuestServiceError.alreadyInFlight
        }
        inFlightVerifications.withLock { _ = $0.insert(logName) }
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
        // Route the enqueued save to the shared engine unless the acting user owns the family zone.
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)

        dispatchRejectionNotification(for: updated)
        return updated
    }

    // MARK: - Validation Helpers

    private func validateCanCompleteQuest(_ quest: Quest, questName: String) throws {
        if let cachedQuest = cacheService?.fetchQuest(recordName: questName, family: quest.family.recordID.recordName) {
            guard cachedQuest.isActive else {
                throw QuestServiceError.alreadyCompleted
            }
            if let expectedTag = quest.changeTag, let currentTag = cachedQuest.changeTag, expectedTag != currentTag {
                throw QuestServiceError.staleData("quest was updated on another device")
            }
        }
        let cachedLogs = cachedQuestLogs(forQuest: quest)
        let cachedNonRejectedCount = cachedLogs.filter(\.verificationStatus.countsTowardCompletion).count
        if GoldCalculation.nonRejectedLogsReachTarget(quest: quest, nonRejectedCount: cachedNonRejectedCount) {
            throw QuestServiceError.alreadyCompleted
        }
        if quest.approvalMode == .parentVerify, cachedLogs.contains(where: { $0.verificationStatus == .pending }) {
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
        if let parent = resolveParent(recordID: quest.createdBy.recordID, familyRecordName: quest.family.recordID.recordName) {
            if let notificationService {
                Task { @Sendable [logger] in
                    do {
                        try await notificationService.sendQuestNeedsReview(questLog: log, to: parent)
                    } catch {
                        logger.error("Failed to send quest review notification: \(error, privacy: .public)")
                    }
                }
            }
        } else {
            logger.info("Parent profile not cached; dispatching async review notification")
            if let notificationService {
                let parentID = quest.createdBy.recordID
                Task { [weak self, logger] in
                    guard let self else { return }
                    do {
                        let parent = try await self.cloudKit.fetch(Profile.self, id: parentID)
                        self.cacheService?.upsertProfile(parent)
                        try await notificationService.sendQuestNeedsReview(questLog: log, to: parent)
                    } catch {
                        logger.error("Failed to send async quest review notification: \(error, privacy: .public)")
                    }
                }
            }
        }
    }

    private func dispatchRejectionNotification(for updated: QuestCompletion) {
        if let hero = resolveHero(for: updated) {
            if let notificationService {
                Task { @Sendable [logger] in
                    do {
                        try await notificationService.sendQuestRejected(questLog: updated, to: hero)
                    } catch {
                        logger.error("Failed to send quest rejection notification: \(error, privacy: .public)")
                    }
                }
            }
        } else {
            logger.info("Hero profile not cached during reject; dispatching async rejection notification")
            if let notificationService {
                let heroID = updated.completedBy.recordID
                Task { [weak self, logger] in
                    guard let self else { return }
                    do {
                        let hero = try await self.cloudKit.fetch(Profile.self, id: heroID)
                        self.cacheService?.upsertProfile(hero)
                        try await notificationService.sendQuestRejected(questLog: updated, to: hero)
                    } catch {
                        logger.error("Failed to send async quest rejection notification: \(error, privacy: .public)")
                    }
                }
            }
        }
    }

    private func handlePostVerifySettlement(questLog: QuestCompletion, updated: QuestCompletion) async throws {
        let quest: Quest
        let hero: Profile

        if let cachedQuest = resolveQuest(for: questLog),
           let cachedHero = resolveHero(for: questLog)
        {
            quest = cachedQuest
            hero = cachedHero
        } else {
            logger.info("Cache miss during verify for quest/hero; resolving synchronously from CloudKit")
            let questID = questLog.quest.recordID
            let heroID = questLog.completedBy.recordID
            quest = try await cloudKit.fetch(Quest.self, id: questID)
            hero = try await cloudKit.fetch(Profile.self, id: heroID)
            cacheService?.upsertQuest(quest)
            cacheService?.upsertProfile(hero)
        }

        let creditedGold = try await applyReward(for: quest, to: hero, completion: updated)

        if let achievementService, let family = appState?.family {
            let achService = achievementService
            Task {
                _ = try? await achService.evaluateAll(for: hero, family: family)
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
                    logger.error("Failed to send quest completion notification: \(error, privacy: .public)")
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
