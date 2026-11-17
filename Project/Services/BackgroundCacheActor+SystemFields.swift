//
//  BackgroundCacheActor+SystemFields.swift
//  LootList
//
//  Created by Ben Mackin on 8/25/26.
//

import Foundation
import os
import SwiftData

/// Sendable descriptor for one server-stamped system-field refresh on an existing cache row.
struct SystemFieldRefresh: Sendable {
    let recordName: String
    let type: CachedRecordType
    let changeTag: String?
    let encodedSystemFields: Data?
    var lastSyncedXP: Int?
}

/// Result of a system-field refresh pass. A Bool return cannot separate "no cached row matched" (legal
/// — rows may have been deleted locally mid-flight) from "the context save failed" (a real cache-write
enum SystemFieldRefreshOutcome: Sendable {
    case updated
    case noMatches
    case saveFailed
}

extension BackgroundCacheActor {
    /// Batch variant of the system-field refresh: applies every descriptor to its cache row and commits all
    /// of them under one context save.
    @discardableResult
    func updateSystemFields(_ refreshes: [SystemFieldRefresh], familyRecordName: String) async -> SystemFieldRefreshOutcome {
        guard !refreshes.isEmpty, await applySystemFieldRefreshes(refreshes, familyRecordName: familyRecordName) else {
            return .noMatches
        }
        return saveContext() ? .updated : .saveFailed
    }

    private func applySystemFieldRefreshes(_ refreshes: [SystemFieldRefresh], familyRecordName: String) async -> Bool {
        var didUpdate = false
        for refresh in refreshes {
            let updated: Bool = switch refresh.type {
            case .profile:
                await updateProfileSystemFields(
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields,
                    lastSyncedXP: refresh.lastSyncedXP
                )
            case .family:
                await updateSystemFields(
                    FamilyCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .quest:
                await updateSystemFields(
                    QuestCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .questTemplate:
                await updateSystemFields(
                    QuestTemplateCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .questCompletion:
                await updateSystemFields(
                    QuestCompletionCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .ledgerEntry:
                await updateSystemFields(
                    LedgerEntryCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .allowancePeriod:
                await updateSystemFields(
                    AllowancePeriodCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .achievement:
                await updateSystemFields(
                    AchievementCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .profileAchievement:
                await updateSystemFields(
                    ProfileAchievementCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .notificationPreference:
                await updateSystemFields(
                    NotificationPreferenceCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .gemLedger:
                await updateSystemFields(
                    GemLedgerCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .rewardEvent:
                await updateSystemFields(
                    RewardEventCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .goal:
                await updateSystemFields(
                    GoalCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            }
            if updated {
                didUpdate = true
            }
        }
        // Absent rows are legal mid-flight deletions, not write failures — a
        // pass that touched nothing must not pay for a context save or report
        // itself as a completed write.
        return didUpdate
    }

    private func updateSystemFields<T: SystemFieldUpdatable>(
        _: T.Type,
        recordName: String,
        familyRecordName: String,
        changeTag: String?,
        encodedSystemFields: Data?
    ) async -> Bool {
        let match: T?
        do { match = try modelContext.fetch(T.fetchDescriptor(recordName: recordName, familyRecordName: familyRecordName)).first } catch {
            logger.error("Failed to fetch \(T.self, privacy: .private) for system-field refresh (\(recordName, privacy: .private)): \(error, privacy: .private)")
            match = nil
        }
        guard let match else {
            // Absence is legal: the row may have been deleted locally mid-flight
            // while this save was outstanding.
            logger.debug("Skipping system-field refresh; no cached row for \(recordName, privacy: .private)")
            return false
        }
        guard match.familyRecordName == familyRecordName || T.self == FamilyCache.self else {
            logger.debug(
                """
                Skipping system-field refresh for \(recordName, privacy: .private): \
                expected family \(familyRecordName, privacy: .private), found \
                \(match.familyRecordName, privacy: .private)
                """
            )
            return false
        }
        match.changeTag = changeTag
        match.encodedSystemFields = encodedSystemFields
        return true
    }

    private func updateProfileSystemFields(
        recordName: String,
        familyRecordName: String,
        changeTag: String?,
        encodedSystemFields: Data?,
        lastSyncedXP: Int?
    ) async -> Bool {
        let match: ProfileCache?
        do {
            match = try modelContext.fetch(
                ProfileCache.fetchDescriptor(recordName: recordName, familyRecordName: familyRecordName)
            ).first
        } catch {
            logger.error("Failed to fetch ProfileCache for system-field refresh (\(recordName, privacy: .private)): \(error, privacy: .private)")
            match = nil
        }
        guard let match, match.familyRecordName == familyRecordName else {
            return false
        }
        match.changeTag = changeTag
        match.encodedSystemFields = encodedSystemFields
        if let lastSyncedXP {
            match.lastSyncedXP = lastSyncedXP
        }
        return true
    }
}

@MainActor
extension CacheService {
    /// Main-context fallback for system-field refreshes when no `BackgroundCacheActor` is attached.
    @discardableResult
    func updateSystemFieldsOnMainActor(
        _ refreshes: [SystemFieldRefresh],
        familyRecordName: String
    ) -> SystemFieldRefreshOutcome {
        guard !refreshes.isEmpty, let context else { return .noMatches }
        var didUpdate = false
        for refresh in refreshes where applyMainActorSystemFieldRefresh(refresh, familyRecordName: familyRecordName, in: context) {
            didUpdate = true
        }
        guard didUpdate else { return .noMatches }
        return saveContext() ? .updated : .saveFailed
    }

    private func applyMainActorSystemFieldRefresh(
        _ refresh: SystemFieldRefresh,
        familyRecordName: String,
        in context: ModelContext
    ) -> Bool {
        switch refresh.type {
        case .profile:
            guard let match = fetchMainActorSystemFieldMatch(
                ProfileCache.self,
                refresh: refresh,
                familyRecordName: familyRecordName,
                in: context
            ) else {
                return false
            }
            match.changeTag = refresh.changeTag
            match.encodedSystemFields = refresh.encodedSystemFields
            if let lastSyncedXP = refresh.lastSyncedXP {
                match.lastSyncedXP = lastSyncedXP
            }
            return true
        case .family:
            return updateMainActorSystemFields(FamilyCache.self, refresh: refresh, familyRecordName: familyRecordName, in: context)
        case .quest:
            return updateMainActorSystemFields(QuestCache.self, refresh: refresh, familyRecordName: familyRecordName, in: context)
        case .questTemplate:
            return updateMainActorSystemFields(QuestTemplateCache.self, refresh: refresh, familyRecordName: familyRecordName, in: context)
        case .questCompletion:
            return updateMainActorSystemFields(QuestCompletionCache.self, refresh: refresh, familyRecordName: familyRecordName, in: context)
        case .ledgerEntry:
            return updateMainActorSystemFields(LedgerEntryCache.self, refresh: refresh, familyRecordName: familyRecordName, in: context)
        case .allowancePeriod:
            return updateMainActorSystemFields(AllowancePeriodCache.self, refresh: refresh, familyRecordName: familyRecordName, in: context)
        case .achievement:
            return updateMainActorSystemFields(AchievementCache.self, refresh: refresh, familyRecordName: familyRecordName, in: context)
        case .profileAchievement:
            return updateMainActorSystemFields(ProfileAchievementCache.self, refresh: refresh, familyRecordName: familyRecordName, in: context)
        case .notificationPreference:
            return updateMainActorSystemFields(NotificationPreferenceCache.self, refresh: refresh, familyRecordName: familyRecordName, in: context)
        case .gemLedger:
            return updateMainActorSystemFields(GemLedgerCache.self, refresh: refresh, familyRecordName: familyRecordName, in: context)
        case .rewardEvent:
            return updateMainActorSystemFields(RewardEventCache.self, refresh: refresh, familyRecordName: familyRecordName, in: context)
        case .goal:
            return updateMainActorSystemFields(GoalCache.self, refresh: refresh, familyRecordName: familyRecordName, in: context)
        }
    }

    private func updateMainActorSystemFields<T: SystemFieldUpdatable>(
        _: T.Type,
        refresh: SystemFieldRefresh,
        familyRecordName: String,
        in context: ModelContext
    ) -> Bool {
        guard let match = fetchMainActorSystemFieldMatch(
            T.self,
            refresh: refresh,
            familyRecordName: familyRecordName,
            in: context
        ) else {
            return false
        }
        match.changeTag = refresh.changeTag
        match.encodedSystemFields = refresh.encodedSystemFields
        return true
    }

    private func fetchMainActorSystemFieldMatch<T: SystemFieldUpdatable>(
        _: T.Type,
        refresh: SystemFieldRefresh,
        familyRecordName: String,
        in context: ModelContext
    ) -> T? {
        let match: T?
        do {
            match = try context.fetch(
                T.fetchDescriptor(recordName: refresh.recordName, familyRecordName: familyRecordName)
            ).first
        } catch {
            logger.error("Failed to fetch \(T.self, privacy: .private) for main-actor system-field refresh (\(refresh.recordName, privacy: .private)): \(error, privacy: .private)")
            return nil
        }
        guard let match, match.familyRecordName == familyRecordName || T.self == FamilyCache.self else {
            return nil
        }
        return match
    }
}

/// Minimal protocol surface for refreshing server-owned system fields on a
/// cached row, so the generic refresh helper needs no per-type domain-model
/// merge scaffolding.
private protocol SystemFieldUpdatable: CacheMergeable {
    var changeTag: String? { get set }
    var encodedSystemFields: Data? { get set }
    static func fetchDescriptor(recordName: String, familyRecordName: String) -> FetchDescriptor<Self>
}

extension ProfileCache: SystemFieldUpdatable {}
extension FamilyCache: SystemFieldUpdatable {}
extension QuestCache: SystemFieldUpdatable {}
extension QuestTemplateCache: SystemFieldUpdatable {}
extension QuestCompletionCache: SystemFieldUpdatable {}
extension LedgerEntryCache: SystemFieldUpdatable {}
extension AllowancePeriodCache: SystemFieldUpdatable {}
extension AchievementCache: SystemFieldUpdatable {}
extension ProfileAchievementCache: SystemFieldUpdatable {}
extension NotificationPreferenceCache: SystemFieldUpdatable {}
extension GemLedgerCache: SystemFieldUpdatable {}
extension RewardEventCache: SystemFieldUpdatable {}
extension GoalCache: SystemFieldUpdatable {}
