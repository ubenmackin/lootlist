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
        guard let acting = appState?.currentProfile,
              acting.id == profile.id
        else {
            throw FamilyServiceError.unauthorized
        }
        let questName = quest.id.recordName
        if inFlightCompletions.withLock({ $0.contains(questName) }) {
            toastManager?.show(message: "This quest is already being completed.", type: .info)
            throw QuestServiceError.alreadyInFlight
        }
        inFlightCompletions.withLock { _ = $0.insert(questName) }
        defer { inFlightCompletions.withLock { _ = $0.remove(questName) } }
        let cachedLogs = cachedQuestLogs(forQuest: quest)
        let cachedNonRejectedCount = cachedLogs.filter(\.verificationStatus.countsTowardCompletion).count
        if GoldCalculation.nonRejectedLogsReachTarget(quest: quest, nonRejectedCount: cachedNonRejectedCount) {
            throw QuestServiceError.alreadyCompleted
        }
        if quest.approvalMode == .parentVerify, cachedLogs.contains(where: { $0.verificationStatus == .pending }) {
            toastManager?.show(message: "The previous completion is awaiting parent verification.", type: .info)
            throw QuestServiceError.alreadyInFlight
        }
        var log = QuestCompletion(quest: CKRecord.Reference(recordID: quest.id, action: .none),
                                  completedBy: CKRecord.Reference(recordID: profile.id, action: .none),
                                  approvalMode: quest.approvalMode, weekOf: quest.weekOf, family: quest.family)
        log.completedDate = completedDate
        let reg = cacheService?.inFlightRegistry
        await reg?.register(log.id.recordName)
        cacheService?.upsertQuestCompletion(log)
        do {
            let saved = try await cloudKit.save(log)
            cacheService?.upsertQuestCompletion(saved)
            switch quest.approvalMode {
            case .autoApprove: try await applyReward(for: quest, to: profile, completion: saved)
            case .parentVerify:
                if let notificationService, let parent = try? await cloudKit.fetch(Profile.self, id: quest.createdBy.recordID) {
                    Task { @Sendable [logger] in
                        do { try await notificationService.sendQuestNeedsReview(questLog: saved, to: parent) } catch {
                            logger.error("Failed to send quest review notification: \(error, privacy: .public)")
                        }
                    }
                }
            }
            await reg?.deregister(log.id.recordName)
            return saved
        } catch {
            await handleSaveFailure(
                recordID: log.id,
                fetchCurrentTag: {
                    self.cacheService?.fetchQuestCompletions(family: quest.family.recordID.recordName).first(where: { $0.recordName == log.id.recordName })?.changeTag
                },
                upsert: { self.cacheService?.upsertQuestCompletion($0) },
                invalidate: { self.cacheService?.invalidateQuestCompletion(recordName: $0) },
                error: error
            )
            await reg?.deregister(log.id.recordName)
            throw error
        }
    }

    func withdrawCompletion(questLog: QuestCompletion, by profile: Profile) async throws {
        guard let acting = appState?.currentProfile,
              acting.id == profile.id || acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }
        guard questLog.verificationStatus == .pending else {
            throw QuestServiceError.alreadyResolved(questLog.verificationStatus.rawValue)
        }

        // Pending submissions are append-only: unsubmitting is a state
        // transition (pending → withdrawn) that keeps the completion record
        // inserted, never a delete. The withdrawn log no longer occupies a
        // completion slot, so a later `markComplete` is allowed to proceed.
        var updated = questLog
        updated.verificationStatus = .withdrawn

        let name = questLog.id.recordName
        let snapshot = cacheService?.fetchQuestCompletions(family: questLog.family.recordID.recordName).first(where: { $0.recordName == name })
        let preMutationChangeTag = snapshot?.changeTag
        let snapshotCompletion: QuestCompletion? = snapshot?.toQuestCompletion(zoneID: cloudKit.resolvedZoneID)

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertQuestCompletion(updated)
        do {
            let saved = try await cloudKit.save(updated)
            cacheService?.upsertQuestCompletion(saved)
            await registry?.deregister(name)
        } catch {
            // On failure the pre-mutation snapshot (the pending row) is
            // restored, so the cache never drops a record the source of truth
            // still holds — withdrawal is state-based, with no delete to fold
            // back in.
            await handleSaveFailure(
                recordID: questLog.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotCompletion,
                fetchCurrentTag: { self.cacheService?.fetchQuestCompletions(family: questLog.family.recordID.recordName).first(where: { $0.recordName == name })?.changeTag },
                upsert: { self.cacheService?.upsertQuestCompletion($0) },
                invalidate: { self.cacheService?.invalidateQuestCompletion(recordName: $0) },
                error: error
            )
            await registry?.deregister(name)
            throw error
        }
    }

    @discardableResult
    func verify(questLog: QuestCompletion, by parent: Profile) async throws -> QuestCompletion {
        guard let acting = appState?.currentProfile, acting.id == parent.id, acting.role.isParent else { throw FamilyServiceError.unauthorized }
        guard questLog.verificationStatus == .pending else { throw QuestServiceError.alreadyResolved(questLog.verificationStatus.rawValue) }
        var updated = questLog
        updated.verificationStatus = .verified; updated.verifiedBy = CKRecord.Reference(recordID: parent.id, action: .none); updated.verifiedDate = Date()
        let name = questLog.id.recordName
        let snapshot = cacheService?.fetchQuestCompletions(family: questLog.family.recordID.recordName).first(where: { $0.recordName == name })
        let preMutationChangeTag = snapshot?.changeTag
        let snapshotCompletion: QuestCompletion? = snapshot?.toQuestCompletion(zoneID: cloudKit.resolvedZoneID)
        let registry = cacheService?.inFlightRegistry; await registry?.register(name)
        cacheService?.upsertQuestCompletion(updated)
        do {
            let saved = try await cloudKit.save(updated)
            cacheService?.upsertQuestCompletion(saved)
            let quest = try await resolveQuest(for: questLog)
            let hero = try await resolveHero(for: questLog)
            let creditedGold = try await applyReward(for: quest, to: hero, completion: saved)

            if let achievementService, let family = appState?.family {
                let achService = achievementService
                Task {
                    try? await achService.evaluateAll(for: hero, family: family)
                }
            }

            if let notificationService {
                Task { @Sendable [logger] in
                    let goldText = CurrencyFormatter.string(creditedGold)
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

            await registry?.deregister(name)
            return saved
        } catch {
            await handleSaveFailure(
                recordID: questLog.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotCompletion,
                fetchCurrentTag: { self.cacheService?.fetchQuestCompletions(family: questLog.family.recordID.recordName).first(where: { $0.recordName == name })?.changeTag },
                upsert: { self.cacheService?.upsertQuestCompletion($0) },
                invalidate: { self.cacheService?.invalidateQuestCompletion(recordName: $0) },
                error: error
            )
            await registry?.deregister(name)
            throw error
        }
    }

    @discardableResult
    func reject(questLog: QuestCompletion, by parent: Profile) async throws -> QuestCompletion {
        guard let acting = appState?.currentProfile,
              acting.id == parent.id,
              acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }
        guard questLog.verificationStatus == .pending else {
            throw QuestServiceError.alreadyResolved(questLog.verificationStatus.rawValue)
        }

        var updated = questLog
        updated.verificationStatus = .rejected
        updated.verifiedBy = CKRecord.Reference(recordID: parent.id, action: .none)
        updated.verifiedDate = Date()

        let name = questLog.id.recordName
        let snapshot = cacheService?.fetchQuestCompletions(family: questLog.family.recordID.recordName).first(where: { $0.recordName == name })

        let preMutationChangeTag = snapshot?.changeTag
        let snapshotCompletion: QuestCompletion? = snapshot?.toQuestCompletion(zoneID: cloudKit.resolvedZoneID)

        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertQuestCompletion(updated)
        do {
            let saved = try await cloudKit.save(updated)
            cacheService?.upsertQuestCompletion(saved)
            await registry?.deregister(name)
            return saved
        } catch {
            await handleSaveFailure(
                recordID: questLog.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotCompletion,
                fetchCurrentTag: { self.cacheService?.fetchQuestCompletions(family: questLog.family.recordID.recordName).first(where: { $0.recordName == name })?.changeTag },
                upsert: { self.cacheService?.upsertQuestCompletion($0) },
                invalidate: { self.cacheService?.invalidateQuestCompletion(recordName: $0) },
                error: error
            )
            await registry?.deregister(name)
            throw error
        }
    }

    // MARK: - Private Helpers

    /// Cache-first quest resolution for the reward step of `verify`. Returns
    /// the cached quest when the family's quest cache is fresh
    /// (freshness watermark); falls back to a single CloudKit fetch on a stale or
    /// partial cache.
    private func resolveQuest(for questLog: QuestCompletion) async throws -> Quest {
        let questID = questLog.quest.recordID
        let familyName = questLog.family.recordID.recordName
        if let cache = cacheService, cache.isCacheFresh(familyRecordName: familyName, type: .quest),
           let cached = cache.fetchQuests(family: familyName).first(where: { $0.recordName == questID.recordName })
        {
            return cached.toQuest(zoneID: cloudKit.resolvedZoneID)
        }
        return try await cloudKit.fetch(Quest.self, id: questID)
    }

    /// Cache-first hero (completer) resolution for the reward step of `verify`.
    /// CloudKit is only consulted when the family's profile cache is stale or
    /// the profile is absent from it.
    private func resolveHero(for questLog: QuestCompletion) async throws -> Profile {
        let heroID = questLog.completedBy.recordID
        let familyName = questLog.family.recordID.recordName
        if let cache = cacheService, cache.isCacheFresh(familyRecordName: familyName, type: .profile),
           let cached = cache.fetchProfile(recordName: heroID.recordName)
        {
            return cached.toProfile(zoneID: cloudKit.resolvedZoneID)
        }
        return try await cloudKit.fetch(Profile.self, id: heroID)
    }

    /// Strictly-local cached logs for a quest, sorted newest-first. Unlike
    /// `fetchQuestLogs(forQuest:useCache:)` this NEVER falls through to a
    /// CloudKit query — it exists for the pre-write path of `markComplete`
    /// where any network round-trip would break the 0ms mutation promise.
    private func cachedQuestLogs(forQuest quest: Quest) -> [QuestCompletion] {
        guard let cache = cacheService else { return [] }
        let questName = quest.id.recordName
        return cache.fetchQuestCompletions(family: quest.family.recordID.recordName)
            .filter { $0.questRecordName == questName }
            .map { $0.toQuestCompletion(zoneID: cloudKit.resolvedZoneID) }
            .sorted { $0.completedDate > $1.completedDate }
    }
}
