//
//  CKSyncConflictResolver.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CloudKit
import Foundation
import os
import SwiftData

/// Handles asynchronous conflict resolution for record saves that fail within `CKSyncEngine`.
@MainActor
final class CKSyncConflictResolver {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "CKSyncConflictResolver"
    )

    private let cacheService: CacheService?
    private let backgroundCache: BackgroundCacheActor?
    private weak var toastManager: ToastManager?
    private weak var appState: AppState?
    weak var coordinator: CKSyncEngineCoordinator?

    init(
        cacheService: CacheService? = nil,
        backgroundCache: BackgroundCacheActor? = nil,
        toastManager: ToastManager? = nil,
        appState: AppState? = nil,
        coordinator: CKSyncEngineCoordinator? = nil
    ) {
        self.cacheService = cacheService
        self.backgroundCache = backgroundCache
        self.toastManager = toastManager
        self.appState = appState
        self.coordinator = coordinator
    }

    /// Resolves a single failed record save. Returns a resolved `CKRecord` if the record
    /// should be re-saved to CloudKit, or `nil` if the conflict was resolved by adopting server state.
    func resolveFailedSave(
        record: CKRecord,
        error: Error
    ) async -> CKRecord? {
        guard let ckError = error as? CKError else {
            logger.error("Non-CKError during save: \(error, privacy: .private)")
            return nil
        }

        switch ckError.code {
        case .serverRecordChanged:
            return await handleServerRecordChanged(ckError: ckError, originalRecord: record)

        case .unknownItem, .zoneNotFound:
            let derivedFamily = appState?.family?.id.recordName
                ?? (record["family"] as? CKRecord.Reference)?.recordID.recordName
                ?? record.parent?.recordID.recordName
            guard let derivedFamily else {
                logger.warning("resolveFailedSave could not resolve family for deleted record \(record.recordID.recordName, privacy: .private)")
                return nil
            }
            let scope: CKDatabase.Scope = (appState?.isZoneOwner == true) ? .private : ((record.recordID.zoneID.ownerName == CKCurrentUserDefaultName) ? .private : .shared)
            await handleDeletedRecord(
                recordID: record.recordID,
                recordType: record.recordType,
                databaseScope: scope,
                familyRecordName: derivedFamily
            )
            return nil

        case .quotaExceeded:
            logger.error("iCloud storage quota exceeded while saving \(record.recordID.recordName, privacy: .private)")
            return nil

        default:
            logger.warning("Unresolved CloudKit save failure (\(ckError.code.rawValue)): \(error, privacy: .private)")
            return nil
        }
    }

    private func handleServerRecordChanged(
        ckError: CKError,
        originalRecord: CKRecord
    ) async -> CKRecord? {
        guard let serverRecordRaw = ckError.serverRecord else {
            logger.warning("serverRecordChanged error missing serverRecord")
            return nil
        }

        let serverRecord = mergeFields(clientRecord: originalRecord, serverRecord: serverRecordRaw)

        logger.info("Resolving serverRecordChanged conflict for \(serverRecord.recordType) id=\(serverRecord.recordID.recordName, privacy: .private)")

        switch serverRecord.recordType {
        case Quest.recordType:
            return resolveQuestConflict(serverRecord: serverRecord, originalRecord: originalRecord)
        case Profile.recordType:
            return resolveProfileConflict(serverRecord: serverRecord, originalRecord: originalRecord)
        case QuestCompletion.recordType:
            return resolveQuestCompletionConflict(serverRecord: serverRecord, originalRecord: originalRecord)
        default:
            break
        }

        // For other models, parse server record and update cache as source of truth
        let parsedRecord = ParsedRecord.parse(record: serverRecord)
        switch parsedRecord {
        case .parseFailure:
            coordinator?.noteParseFailure()
            logger.error("Parse failure for conflicted server record: type=\(serverRecord.recordType, privacy: .public), id=\(serverRecord.recordID.recordName, privacy: .private)")
        case .ignoredSystemRecord:
            logger.debug("Ignored system record in conflict resolver: type=\(serverRecord.recordType, privacy: .public)")
        default:
            await backgroundCache?.batchUpsertParsedRecords([parsedRecord])
        }

        return nil
    }

    /// Monotonic XP-credit merge for `Quest.xpBanked`. Concurrent completions
    /// across devices must never undercount the banked total, so the merged
    /// value is `max(server, client)`. Merged model builds upon `serverRecord`
    /// (retaining server-authoritative fields with client-wins display fields overlaid).
    private func resolveQuestConflict(serverRecord: CKRecord, originalRecord: CKRecord) -> CKRecord? {
        let serverBanked = serverRecord["xpBanked"] as? Int ?? 0
        let clientBanked = originalRecord["xpBanked"] as? Int ?? 0
        let rawMergedBanked = max(serverBanked, clientBanked)

        var mergedQuest: Quest
        do {
            mergedQuest = try Quest(record: serverRecord)
        } catch {
            logger.warning("Failed to decode Quest from server record: \(error, privacy: .private)")
            toastManager?.show(message: "A quest couldn't be synced. Pull down to refresh.", type: .warning)
            return nil
        }
        let mergedBanked = min(rawMergedBanked, mergedQuest.xpReward)
        mergedQuest.xpBanked = mergedBanked
        mergedQuest.changeTag = serverRecord.recordChangeTag
        mergedQuest.encodedSystemFields = serverRecord.encodedSystemFields
        cacheService?.upsertQuest(mergedQuest, isServerSync: true)

        let mergedRecord = mergedQuest.toRecord()
        mergedRecord.parent = serverRecord.parent
        return mergedRecord
    }

    /// Additive XP merge for `Profile.xp`. Computes offline delta earned on this device
    /// (`clientXP - lastSyncedXP`) and merges additively with server XP (`serverXP + delta`),
    /// ensuring concurrent offline earnings on multiple devices are preserved.
    /// Retains server-authoritative fields with client-wins display fields overlaid.
    private func resolveProfileConflict(serverRecord: CKRecord, originalRecord: CKRecord) -> CKRecord? {
        let serverXP = serverRecord["xp"] as? Int ?? 0
        let clientXP = originalRecord["xp"] as? Int ?? 0

        let profileName = originalRecord.recordID.recordName
        let familyName = (serverRecord["family"] as? CKRecord.Reference)?.recordID.recordName
            ?? (originalRecord["family"] as? CKRecord.Reference)?.recordID.recordName
        let descriptor = if let familyName {
            FetchDescriptor<ProfileCache>(
                predicate: #Predicate { $0.recordName == profileName && $0.familyRecordName == familyName }
            )
        } else {
            FetchDescriptor<ProfileCache>(
                predicate: #Predicate { $0.recordName == profileName }
            )
        }
        let cachedProfile: ProfileCache?
        do {
            cachedProfile = try cacheService?.context?.fetch(descriptor).first
        } catch {
            logger.warning("Failed to fetch cached Profile for conflict delta: \(error, privacy: .private)")
            cachedProfile = nil
        }

        let mergedXP: Int
        if let cachedProfile {
            let lastSyncedXP = cachedProfile.lastSyncedXP
            let clientDelta = max(clientXP - lastSyncedXP, 0)
            mergedXP = max(serverXP + clientDelta, max(serverXP, clientXP))
        } else {
            mergedXP = max(serverXP, clientXP)
        }

        var mergedProfile: Profile
        do {
            mergedProfile = try Profile(record: serverRecord)
        } catch {
            logger.warning("Failed to decode Profile from server record: \(error, privacy: .private)")
            toastManager?.show(message: "A profile update couldn't be synced. Pull down to refresh.", type: .warning)
            return nil
        }
        mergedProfile.xp = mergedXP
        mergedProfile.level = XPService.level(forXP: mergedXP)
        // Union-merge ownership/claim ledgers so a concurrent purchase or
        // bonus-objective claim on another device is never dropped (gems are
        // debited via the append-only GemLedger; losing the ownership/claim
        // marker here would make the paid item vanish). Equipped selection is
        // cosmetic (one item per category) and stays server-wins.
        let serverOwned = serverRecord["ownedEquipment"] as? [String] ?? []
        let clientOwned = originalRecord["ownedEquipment"] as? [String] ?? []
        let serverClaimed = serverRecord["claimedBonusObjectives"] as? [String] ?? []
        let clientClaimed = originalRecord["claimedBonusObjectives"] as? [String] ?? []
        mergedProfile.ownedEquipment = Self.orderedUnion(serverOwned, clientOwned)
        mergedProfile.claimedBonusObjectives = Self.orderedUnion(serverClaimed, clientClaimed)

        // Preserve newly introduced fields when resolving a conflict against a
        // legacy server record that has not stored them yet.
        if serverRecord["gems"] == nil {
            mergedProfile.gems = originalRecord["gems"] as? Int ?? mergedProfile.gems
        }
        if serverRecord["streakShields"] == nil {
            mergedProfile.streakShields = originalRecord["streakShields"] as? Int ?? mergedProfile.streakShields
        }
        if serverRecord["equippedItems"] == nil {
            mergedProfile.equippedItems = originalRecord["equippedItems"] as? [String] ?? mergedProfile.equippedItems
        }

        let serverClaimDay = serverRecord["dailyLoginLastClaimDay"] as? String
        let clientClaimDay = originalRecord["dailyLoginLastClaimDay"] as? String
        let serverStreak = serverRecord["dailyLoginStreakDays"] as? Int ?? 0
        let clientStreak = originalRecord["dailyLoginStreakDays"] as? Int ?? 0
        let clientDailyStateIsNewer: Bool = {
            guard let clientClaimDay else { return false }
            guard let serverClaimDay else { return true }
            return clientClaimDay > serverClaimDay
                || (clientClaimDay == serverClaimDay && clientStreak > serverStreak)
        }()
        if clientDailyStateIsNewer {
            mergedProfile.dailyLoginLastClaimDay = clientClaimDay
            mergedProfile.dailyLoginCycleDay = originalRecord["dailyLoginCycleDay"] as? Int ?? 1
            mergedProfile.dailyLoginStreakDays = clientStreak
            mergedProfile.streakShields = originalRecord["streakShields"] as? Int ?? mergedProfile.streakShields
        }
        mergedProfile.changeTag = serverRecord.recordChangeTag
        mergedProfile.encodedSystemFields = serverRecord.encodedSystemFields
        cacheService?.upsertProfile(mergedProfile, isServerSync: true)

        let mergedRecord = mergedProfile.toRecord()
        mergedRecord.parent = serverRecord.parent
        return mergedRecord
    }

    private static func orderedUnion(_ first: [String], _ second: [String]) -> [String] {
        var result = first
        for value in second where !result.contains(value) {
            result.append(value)
        }
        return result
    }

    /// Idempotency-marker merge for `QuestCompletion.xpCredited`. Once either
    /// side has credited the completion, the non-nil marker is preserved so a
    /// re-delivered completion can never be re-minted for a second XP award.
    /// Status transitions and verification dates are server-authoritative.
    private func resolveQuestCompletionConflict(serverRecord: CKRecord, originalRecord: CKRecord) -> CKRecord? {
        let clientCredited = originalRecord["xpCredited"] as? Int

        var merged: QuestCompletion
        do {
            merged = try QuestCompletion(record: serverRecord)
        } catch {
            logger.warning("Failed to decode QuestCompletion from server record: \(error, privacy: .private)")
            toastManager?.show(message: "A completed quest couldn't be synced. Pull down to refresh.", type: .warning)
            return nil
        }
        if merged.xpCredited == nil, let clientCredited {
            merged.xpCredited = clientCredited
        }
        merged.changeTag = serverRecord.recordChangeTag
        merged.encodedSystemFields = serverRecord.encodedSystemFields
        cacheService?.upsertQuestCompletion(merged, isServerSync: true)

        let mergedRecord = merged.toRecord()
        mergedRecord.parent = serverRecord.parent
        return mergedRecord
    }

    /// Client-wins display fields per record type. Server wins for state/status
    /// fields; client wins for user-authored display fields. See
    /// ARCHITECTURE.md §Conflict Resolution for full merge semantics.
    private static let clientWinsFields: [String: Set<String>] = [
        Quest.recordType: ["name", "descriptionText"],
        Profile.recordType: ["displayName", "avatarClass", "avatarPresetID", "customAvatarImageData"]
    ]

    /// Performs field-level merge of a conflict. For fields the client can win,
    /// the local value is preserved on top of the server record. For all other
    /// fields, the server value stands.
    private func mergeFields(
        clientRecord: CKRecord,
        serverRecord: CKRecord
    ) -> CKRecord {
        let recordType = serverRecord.recordType
        let allowedClientFields = Self.clientWinsFields[recordType] ?? []

        // Start with the server record (it has the correct change tag and
        // system fields). Overlay client-wins fields from the local copy.
        for fieldKey in allowedClientFields {
            if let clientValue = clientRecord[fieldKey] {
                serverRecord[fieldKey] = clientValue
            }
        }

        return serverRecord
    }

    func handleDeletedRecord(
        recordID: CKRecord.ID,
        recordType: String,
        databaseScope: CKDatabase.Scope,
        familyRecordName: String
    ) async {
        let identity = ScopedRecordIdentity(
            databaseScope: databaseScope,
            zoneID: recordID.zoneID,
            recordID: recordID,
            familyRecordName: familyRecordName
        )
        logger
            .info(
                "Record \(recordID.recordName, privacy: .private) deleted server-side (scope=\(databaseScope.rawValue), zone=\(recordID.zoneID.zoneName, privacy: .private)); invalidating local cache"
            )
        if let cachedType = CachedRecordType.recordType(for: recordType) {
            if let cacheService {
                cacheService.invalidateRecord(
                    identity: identity,
                    type: cachedType
                )
            }
            if let backgroundCache {
                await backgroundCache.deleteRecord(
                    identity: identity,
                    type: cachedType
                )
            }
        }
    }
}
