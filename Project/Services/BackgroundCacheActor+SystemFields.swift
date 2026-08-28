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
        guard !refreshes.isEmpty else { return .noMatches }
        guard await applySystemFieldRefreshes(refreshes, familyRecordName: familyRecordName) else {
            return .noMatches
        }
        return saveContext() ? .updated : .saveFailed
    }

    private func applySystemFieldRefreshes(_ refreshes: [SystemFieldRefresh], familyRecordName: String) async -> Bool {
        var didUpdate = false
        for refresh in refreshes {
            let updated: Bool = switch refresh.type {
            case .profile:
                await updateSystemFields(
                    ProfileCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
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
        do { match = try modelContext.fetch(T.fetchDescriptor(recordName: recordName)).first } catch {
            logger.error("Failed to fetch \(T.self, privacy: .private) for system-field refresh (\(recordName, privacy: .private)): \(error, privacy: .private)")
            match = nil
        }
        guard let match else {
            // Absence is legal: the row may have been deleted locally mid-flight
            // while this save was outstanding.
            logger.debug("Skipping system-field refresh; no cached row for \(recordName, privacy: .private)")
            return false
        }
        guard match.familyRecordName == familyRecordName else {
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
}

/// Minimal protocol surface for refreshing server-owned system fields on a
/// cached row, so the generic refresh helper needs no per-type domain-model
/// merge scaffolding.
private protocol SystemFieldUpdatable: CacheMergeable {
    var changeTag: String? { get set }
    var encodedSystemFields: Data? { get set }
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
