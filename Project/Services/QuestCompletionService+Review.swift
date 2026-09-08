//
//  QuestCompletionService+Review.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import CloudKit
import Foundation
import os

// MARK: - Parent Review & Verification Settlement

extension QuestCompletionService {
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
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: updated.id, appState: appState, logger: logger, context: "QuestCompletionService.verify")

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
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: updated.id, appState: appState, logger: logger, context: "QuestCompletionService.reject")

        dispatchRejectionNotification(for: updated)
        return updated
    }

    // MARK: - Post-Transition Notification & Settlement Helpers

    func dispatchParentReviewNotification(for log: QuestCompletion, quest: Quest) {
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
            Task { @MainActor @Sendable [weak self] in await self?.syncCoordinator.fetchChanges() }
            throw QuestServiceError.missingRecord(questLog.quest.recordID.recordName)
        }

        let creditedGold = try await rewardService.applyReward(for: quest, to: hero, completion: updated)

        if let achievementService, let family = appState.family {
            let achService = achievementService
            Task { @MainActor @Sendable [achService, hero, family, logger] in
                do {
                    _ = try await achService.evaluateAll(for: hero, family: family)
                } catch {
                    logger.warning("Failed to evaluate achievements after quest verification: \(error, privacy: .private)")
                }
            }
        }

        if let notificationService {
            let goldText = CurrencyFormatter.string(pennies: creditedGold)
            Task { @MainActor @Sendable [logger, notificationService, hero, goldText] in
                do {
                    try await notificationService.send(
                        .questCompleted,
                        to: hero,
                        title: "🏆 Quest Verified!",
                        body: "Your quest was verified! You earned \(goldText)."
                    )
                } catch {
                    logger.error("Failed to send quest verification notification: \(error, privacy: .private)")
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
}
