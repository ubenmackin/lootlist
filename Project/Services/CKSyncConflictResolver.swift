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
///
/// Frozen conflict merge semantics per ARCHITECTURE.md §2 — changes require architecture review.
/// Quest banked XP: max(server,client) capped at xpReward. Profile XP: max(server+max(client-lastSynced,0),
/// max(server,client)) with lastSyncedXP advance on isServerSync (see ProfileCache.update). QuestCompletion
/// xpCredited: non-nil preserve (once credited never re-minted). AllowancePeriod: monotonic rank
/// paid > payoutPending > active plus max(totalEarned/questsCompleted/paidAmount) and server-preferred paidDate
/// with client fallback. Quest/Profile display fields use client-wins overlay; Hero Board claim races resolve
/// via standard server-wins (loser's ingest reveals the other claimer). All merges carry post-merge
/// changeTag/encodedSystemFields via a single background batch.
@MainActor
final class CKSyncConflictResolver {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "CKSyncConflictResolver"
    )

    private let cacheService: CacheService?
    private var backgroundCache: BackgroundCacheActor?
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

    func setBackgroundCache(_ backgroundCache: BackgroundCacheActor) {
        self.backgroundCache = backgroundCache
    }

    /// Resolves a single failed record save. Returns a resolved `CKRecord` if the record should be re-saved
    /// to CloudKit, or `nil` if the conflict was resolved by adopting server state.
    func resolveFailedSave(
        record: CKRecord,
        error: Error,
        databaseScope: CKDatabase.Scope? = nil
    ) async -> CKRecord? {
        guard let ckError = error as? CKError else {
            logger.error("Non-CKError during save: \(error, privacy: .private)")
            return nil
        }

        switch ckError.code {
        case .serverRecordChanged:
            return await handleServerRecordChanged(ckError: ckError, originalRecord: record)

        case .unknownItem, .zoneNotFound:
            // Family derivation: appState → record's family reference → parent record → zoneName fallback.
            let derivedFamily: String = appState?.family?.id.recordName
                ?? (record["family"] as? CKRecord.Reference)?.recordID.recordName
                ?? record.parent?.recordID.recordName
                ?? record.recordID.zoneID.zoneName
            guard !derivedFamily.isEmpty else {
                logger.warning("resolveFailedSave could not resolve family for deleted record \(record.recordID.recordName, privacy: .private)")
                return nil
            }
            let scope: CKDatabase.Scope = if let databaseScope {
                databaseScope
            } else if let appState {
                appState.activeDatabaseScope
            } else {
                DatabaseScopeResolver.scope(isOwner: record.recordID.zoneID.ownerName == CKCurrentUserDefaultName)
            }
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

        if let coreResult = await coreConflictResult(serverRecord: serverRecord, originalRecord: originalRecord) {
            return coreResult
        }

        await handleSecondaryServerWins(serverRecord: serverRecord, originalRecord: originalRecord)
        return nil
    }

    private func coreConflictResult(serverRecord: CKRecord, originalRecord: CKRecord) async -> CKRecord? {
        switch serverRecord.recordType {
        case Quest.recordType:
            await resolveQuestConflict(serverRecord: serverRecord, originalRecord: originalRecord)
        case Profile.recordType:
            await resolveProfileConflict(serverRecord: serverRecord, originalRecord: originalRecord)
        case QuestCompletion.recordType:
            await resolveQuestCompletionConflict(serverRecord: serverRecord, originalRecord: originalRecord)
        case AllowancePeriod.recordType:
            await resolveAllowancePeriodConflict(serverRecord: serverRecord, originalRecord: originalRecord)
        default:
            nil
        }
    }

    private func handleSecondaryServerWins(serverRecord: CKRecord, originalRecord: CKRecord) async {
        // WHY: Server-wins discards optimistic mutation; surface revert instead of silent flip.
        let parsedRecord = ParsedRecord.parse(record: serverRecord)
        let secondaryType = CachedRecordType.recordType(for: serverRecord.recordType)
        let secondaryFamily: String? = appState?.family?.id.recordName
            ?? (serverRecord["family"] as? CKRecord.Reference)?.recordID.recordName
            ?? (originalRecord["family"] as? CKRecord.Reference)?.recordID.recordName
        let cachedTagBeforeMerge: String? = {
            guard secondaryType != nil, secondaryFamily != nil else { return nil }
            return originalRecord.recordChangeTag
        }()

        switch parsedRecord {
        case .parseFailure:
            coordinator?.noteParseFailure()
            logger.error("Parse failure for conflicted server record: type=\(serverRecord.recordType, privacy: .public), id=\(serverRecord.recordID.recordName, privacy: .private)")
        case .ignoredSystemRecord:
            logger.debug("Ignored system record in conflict resolver: type=\(serverRecord.recordType, privacy: .public)")
        default:
            await commitSecondaryParsedRecord(parsedRecord)
            surfaceSecondaryRevertIfNeeded(
                secondaryType: secondaryType,
                secondaryFamily: secondaryFamily,
                cachedTagBeforeMerge: cachedTagBeforeMerge,
                serverRecord: serverRecord,
                originalRecord: originalRecord
            )
        }
    }

    private func commitSecondaryParsedRecord(_ parsedRecord: ParsedRecord) async {
        if let backgroundCache {
            await backgroundCache.batchUpsertParsedRecords([parsedRecord])
            return
        }
        guard let cacheService else { return }
        // WHY: Third sanctioned exception per ARCHITECTURE.md §2 — in-memory fallback when BackgroundCacheActor unavailable; mirrors ingest isServerSync semantics.
        if await commitPrimaryFallback(parsedRecord, cacheService: cacheService) {
            return
        }
        await commitRemainingFallback(parsedRecord, cacheService: cacheService)
    }

    private func commitPrimaryFallback(_ parsedRecord: ParsedRecord, cacheService: CacheService) async -> Bool {
        switch parsedRecord {
        case let .ledgerEntry(entry): await cacheService.upsertLedgerEntry(entry, isServerSync: true)
        case let .goal(goal): await cacheService.upsertGoal(goal, isServerSync: true)
        case let .profile(profile): await cacheService.upsertProfile(profile, isServerSync: true)
        case let .family(family): await cacheService.upsertFamily(family)
        case let .quest(quest): await cacheService.upsertQuest(quest, isServerSync: true)
        case let .questTemplate(template): await cacheService.upsertQuestTemplate(template, isServerSync: true)
        case let .questCompletion(completion): await cacheService.upsertQuestCompletion(completion, isServerSync: true)
        default: return false
        }
        return true
    }

    private func commitRemainingFallback(_ parsedRecord: ParsedRecord, cacheService: CacheService) async {
        switch parsedRecord {
        case let .allowancePeriod(period): await cacheService.upsertAllowancePeriod(period, isServerSync: true)
        case let .achievement(achievement): await cacheService.upsertAchievement(achievement, isServerSync: true)
        case let .profileAchievement(profileAchievement): await cacheService.upsertProfileAchievement(profileAchievement, isServerSync: true)
        case let .notificationPreference(preference): await cacheService.upsertNotificationPreference(preference, isServerSync: true)
        case let .gemLedger(ledger): await cacheService.upsertGemLedger(ledger, isServerSync: true)
        case let .rewardEvent(event): await cacheService.upsertRewardEvent(event, isServerSync: true)
        case .ignoredSystemRecord, .parseFailure: break
        default: break
        }
    }

    private func surfaceSecondaryRevertIfNeeded(
        secondaryType: CachedRecordType?,
        secondaryFamily: String?,
        cachedTagBeforeMerge: String?,
        serverRecord: CKRecord,
        originalRecord: CKRecord
    ) {
        guard let secondaryType, let secondaryFamily else {
            if secondaryFamily == nil, let secondaryType {
                let typeLabel = String(describing: secondaryType)
                let recordName = serverRecord.recordID.recordName
                logger.fault(
                    "Could not resolve family for secondary conflict revert — skipping freshness invalidation for \(typeLabel, privacy: .public) id=\(recordName, privacy: .private)"
                )
            }
            return
        }
        let serverTag = serverRecord.recordChangeTag
        let shouldSurface: Bool = {
            if let cachedTagBeforeMerge, let serverTag {
                // WHY: cached tag divergence proves an optimistic write was clobbered by server-wins.
                return cachedTagBeforeMerge != serverTag
            }
            // Fallback when tags unavailable — compare local pending fields to server snapshot.
            return didLocalFieldsDiffer(serverRecord: serverRecord, clientRecord: originalRecord)
        }()
        guard shouldSurface else { return }
        cacheService?.invalidateFreshness(familyRecordName: secondaryFamily, type: secondaryType)
        let message = switch secondaryType {
        case .ledgerEntry: "Your spending change was reverted by newer server data. Pull to refresh."
        case .goal: "Your goal update was reverted by newer server data. Pull to refresh."
        case .profile: "Your profile change was reverted by newer server data. Pull to refresh."
        default: "Your recent change was reverted — server data won. Pull to refresh."
        }
        toastManager?.show(message: message, type: .warning)
    }

    /// FROZEN — Quest xpBanked monotonic merge per ARCHITECTURE.md §2. Concurrent completions across
    /// devices must never undercount the banked total, so the merged value is `max(server, client)`
    /// capped at `xpReward` to prevent exceeding the quest's budget.
    /// Hero Board claim fields (`claimedByProfileRecordName`, `claimedAt`) are intentionally server-wins
    /// (not in `clientWinsFields`): the loser's ingest adopts the winner's claim and ViewModel
    /// surfaces "Another hero claimed this quest" via settlePendingClaims.
    private func resolveQuestConflict(serverRecord: CKRecord, originalRecord: CKRecord) async -> CKRecord? {
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
        // The background batch applies the same isServerSync merge as the MainActor upsert; the fallback keeps
        // cache state identical when no background actor is wired.
        let parsedMergedRecord = ParsedRecord.parse(record: mergedQuest.toRecord())
        if case .parseFailure = parsedMergedRecord {
            logger.error("Merged Quest failed to re-parse (\(mergedQuest.id.recordName, privacy: .private)); committing via main-context upsert instead")
            await cacheService?.upsertQuest(mergedQuest, isServerSync: true)
        } else if let backgroundCache {
            await backgroundCache.batchUpsertParsedRecords([parsedMergedRecord])
        } else {
            await cacheService?.upsertQuest(mergedQuest, isServerSync: true)
        }

        let mergedRecord = mergedQuest.toRecord()
        mergedRecord.parent = serverRecord.parent
        return mergedRecord
    }

    /// FROZEN — Profile XP additive merge per ARCHITECTURE.md §2. Computes offline delta earned on this
    /// device (`clientXP - lastSyncedXP`) and merges as `max(serverXP + max(clientXP - lastSyncedXP, 0),
    /// max(serverXP, clientXP))` with lastSyncedXP advance on isServerSync, ensuring concurrent
    private func resolveProfileConflict(serverRecord: CKRecord, originalRecord: CKRecord) async -> CKRecord? {
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
        // Union-merge ownership/claim ledgers so a concurrent purchase or bonus-objective claim on another
        // device is never dropped (gems are debited via the append-only GemLedger; losing the ownership/claim
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
        if serverRecord["payoutPolicy"] == nil {
            mergedProfile.payoutPolicy = (originalRecord["payoutPolicy"] as? String).flatMap(PayoutPolicy.init(rawValue:))
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

        let serverJourneyLevel = serverRecord["journeyMapLastSeenLevel"] as? Int ?? 1
        let clientJourneyLevel = originalRecord["journeyMapLastSeenLevel"] as? Int ?? 1
        mergedProfile.journeyMapLastSeenLevel = max(serverJourneyLevel, clientJourneyLevel)

        mergedProfile.changeTag = serverRecord.recordChangeTag
        mergedProfile.encodedSystemFields = serverRecord.encodedSystemFields
        // lastSyncedXP advances inside ProfileCache.update(from:isServerSync:) on both the background batch
        // and the MainActor fallback — never via a separate fetch+save, which could re-advance a stale
        let parsedMergedRecord = ParsedRecord.parse(record: mergedProfile.toRecord())
        if case .parseFailure = parsedMergedRecord {
            logger.error("Merged Profile failed to re-parse (\(mergedProfile.id.recordName, privacy: .private)); committing via main-context upsert instead")
            await cacheService?.upsertProfile(mergedProfile, isServerSync: true)
        } else if let backgroundCache {
            await backgroundCache.batchUpsertParsedRecords([parsedMergedRecord])
        } else {
            await cacheService?.upsertProfile(mergedProfile, isServerSync: true)
        }

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

    /// FROZEN — QuestCompletion xpCredited non-nil preserve per ARCHITECTURE.md §2. Once either side
    /// has credited the completion, the non-nil marker is preserved so a re-delivered completion can
    /// never be re-minted for rewards. Must not be changed without architecture review; prevents
    /// double-minting across concurrent devices.
    private func resolveQuestCompletionConflict(serverRecord: CKRecord, originalRecord: CKRecord) async -> CKRecord? {
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
        // The background batch is the primary commit path, but a merged record that fails its toRecord()
        // round-trip would be silently dropped by it — so that case falls back to the MainActor upsert,
        let parsedMergedRecord = ParsedRecord.parse(record: merged.toRecord())
        if case .parseFailure = parsedMergedRecord {
            logger.error("Merged QuestCompletion failed to re-parse (\(merged.id.recordName, privacy: .private)); committing via main-context upsert instead")
            await cacheService?.upsertQuestCompletion(merged, isServerSync: true)
        } else if let backgroundCache {
            await backgroundCache.batchUpsertParsedRecords([parsedMergedRecord])
        } else {
            await cacheService?.upsertQuestCompletion(merged, isServerSync: true)
        }

        let mergedRecord = merged.toRecord()
        mergedRecord.parent = serverRecord.parent
        return mergedRecord
    }

    /// FROZEN — AllowancePeriod monotonic merge per ARCHITECTURE.md §2. Two devices settling the same
    /// period (deterministic `period-{family}-{profile}-{week}` recordName) race through
    /// `getOrCreateAllowancePeriod →` monotonic rank paid(2) > payoutPending(1) > active(0), max amounts
    /// (totalEarned/questsCompleted/paidAmount) plus server-preferred paidDate (server ?? client),
    private func resolveAllowancePeriodConflict(serverRecord: CKRecord, originalRecord: CKRecord) async -> CKRecord? {
        let serverPaidAmount = serverRecord["paidAmount"] as? Double
        let clientPaidAmount = originalRecord["paidAmount"] as? Double
        let mergedPaidAmount: Double? = {
            if serverPaidAmount == nil, clientPaidAmount == nil {
                return nil
            }
            return max(serverPaidAmount ?? 0, clientPaidAmount ?? 0)
        }()

        let serverTotalEarned = serverRecord["totalEarned"] as? Double ?? 0
        let clientTotalEarned = originalRecord["totalEarned"] as? Double ?? 0
        let mergedTotalEarned = max(serverTotalEarned, clientTotalEarned)

        let serverQuestsCompleted = serverRecord["questsCompleted"] as? Int ?? 0
        let clientQuestsCompleted = originalRecord["questsCompleted"] as? Int ?? 0
        let mergedQuestsCompleted = max(serverQuestsCompleted, clientQuestsCompleted)

        let serverStatusRaw = serverRecord["status"] as? String ?? PayoutStatus.active.rawValue
        let clientStatusRaw = originalRecord["status"] as? String ?? PayoutStatus.active.rawValue
        let serverStatus = PayoutStatus(rawValue: serverStatusRaw) ?? .active
        let clientStatus = PayoutStatus(rawValue: clientStatusRaw) ?? .active
        let mergedStatus = payoutRank(serverStatus) >= payoutRank(clientStatus) ? serverStatus : clientStatus

        let serverPaidDate = serverRecord["paidDate"] as? Date
        let clientPaidDate = originalRecord["paidDate"] as? Date
        let mergedPaidDate = serverPaidDate ?? clientPaidDate

        var merged: AllowancePeriod
        do {
            merged = try AllowancePeriod(record: serverRecord)
        } catch {
            logger.warning("Failed to decode AllowancePeriod from server record: \(error, privacy: .private)")
            toastManager?.show(message: "An allowance period couldn't be synced. Pull down to refresh.", type: .warning)
            return nil
        }
        merged.paidAmount = mergedPaidAmount
        merged.totalEarned = mergedTotalEarned
        merged.questsCompleted = mergedQuestsCompleted
        merged.status = mergedStatus
        merged.paidDate = mergedPaidDate
        merged.changeTag = serverRecord.recordChangeTag
        merged.encodedSystemFields = serverRecord.encodedSystemFields
        // The background batch is the primary commit path, but a merged record that fails its toRecord()
        // round-trip would be silently dropped by it — so that case falls back to the MainActor upsert,
        let parsedMergedRecord = ParsedRecord.parse(record: merged.toRecord())
        if case .parseFailure = parsedMergedRecord {
            logger.error("Merged AllowancePeriod failed to re-parse (\(merged.id.recordName, privacy: .private)); committing via main-context upsert instead")
            await cacheService?.upsertAllowancePeriod(merged, isServerSync: true)
        } else if let backgroundCache {
            await backgroundCache.batchUpsertParsedRecords([parsedMergedRecord])
        } else {
            await cacheService?.upsertAllowancePeriod(merged, isServerSync: true)
        }

        let mergedRecord = merged.toRecord()
        mergedRecord.parent = serverRecord.parent
        return mergedRecord
    }

    private func payoutRank(_ status: PayoutStatus) -> Int {
        switch status {
        case .paid: 2
        case .payoutPending: 1
        case .active: 0
        }
    }

    /// FROZEN — Client-wins display fields per ARCHITECTURE.md §2. Quest name/descriptionText and
    /// Profile displayName/avatarClass/avatarPresetID/customAvatarImageData overlay from client onto
    /// server record during merge; all other fields are server-wins. Changes require architecture review.
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

    // WHY: Fallback field diff when changeTags unavailable; surface discard instead of silent flip.
    private func didLocalFieldsDiffer(serverRecord: CKRecord, clientRecord: CKRecord) -> Bool {
        let keys = Set(serverRecord.allKeys()).union(clientRecord.allKeys())
        for key in keys {
            let serverValue = serverRecord[key] as CKRecordValue?
            let clientValue = clientRecord[key] as CKRecordValue?
            if !ckRecordValuesEqual(serverValue, clientValue) {
                return true
            }
        }
        return false
    }

    // WHY: Explicit typed handling before NSObject fallback — prevents
    // Data/Date/NSNumber collisions where String(describing:) would mask
    // differences (e.g., Int(10) vs Double(10.0) or distinct Data bytes).
    private func ckRecordValuesEqual(_ lhs: CKRecordValue?, _ rhs: CKRecordValue?) -> Bool {
        if lhs == nil, rhs == nil {
            return true
        }
        guard let lhs, let rhs else { return false }
        if let result = ckReferenceEquality(lhs, rhs) {
            return result
        }
        if let result = ckReferenceArrayEquality(lhs, rhs) {
            return result
        }
        if let result = ckDataEquality(lhs, rhs) {
            return result
        }
        if let result = ckDateEquality(lhs, rhs) {
            return result
        }
        if let result = ckNumberEquality(lhs, rhs) {
            return result
        }
        if let result = ckArrayEquality(lhs, rhs) {
            return result
        }
        if let lObj = lhs as? NSObject, let rObj = rhs as? NSObject {
            return lObj.isEqual(rObj)
        }
        assertionFailure(
            "ckRecordValuesEqual: unhandled CKRecordValue types "
                + "\(type(of: lhs)) vs \(type(of: rhs))"
        )
        return false
    }

    private func ckArrayElementsEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if let result = ckReferenceEquality(lhs, rhs) {
            return result
        }
        if let result = ckDataEquality(lhs, rhs) {
            return result
        }
        if let result = ckDateEquality(lhs, rhs) {
            return result
        }
        if let result = ckNumberEquality(lhs, rhs) {
            return result
        }
        if let result = ckArrayEquality(lhs, rhs) {
            return result
        }
        if let result = ckStringEquality(lhs, rhs) {
            return result
        }
        if let lObj = lhs as? NSObject, let rObj = rhs as? NSObject {
            return lObj.isEqual(rObj)
        }
        assertionFailure(
            "ckArrayElementsEqual: unhandled element types "
                + "\(type(of: lhs)) vs \(type(of: rhs))"
        )
        return false
    }

    private func ckReferenceEquality(_ lhs: Any, _ rhs: Any) -> Bool? {
        if let lRef = lhs as? CKRecord.Reference,
           let rRef = rhs as? CKRecord.Reference
        {
            return lRef.recordID == rRef.recordID && lRef.action == rRef.action
        }
        if (lhs is CKRecord.Reference) || (rhs is CKRecord.Reference) {
            return false
        }
        return nil
    }

    private func ckReferenceArrayEquality(_ lhs: Any, _ rhs: Any) -> Bool? {
        if let lArr = lhs as? [CKRecord.Reference],
           let rArr = rhs as? [CKRecord.Reference]
        {
            guard lArr.count == rArr.count else { return false }
            for (left, right) in zip(lArr, rArr)
                where left.recordID != right.recordID || left.action != right.action
            {
                return false
            }
            return true
        }
        return nil
    }

    private func ckDataEquality(_ lhs: Any, _ rhs: Any) -> Bool? {
        if let lData = lhs as? Data, let rData = rhs as? Data {
            return lData == rData
        }
        if (lhs is Data) || (rhs is Data) {
            return false
        }
        return nil
    }

    private func ckDateEquality(_ lhs: Any, _ rhs: Any) -> Bool? {
        if let lDate = lhs as? Date, let rDate = rhs as? Date {
            return lDate == rDate
        }
        if (lhs is Date) || (rhs is Date) {
            return false
        }
        return nil
    }

    private func ckNumberEquality(_ lhs: Any, _ rhs: Any) -> Bool? {
        if let lNum = lhs as? NSNumber, let rNum = rhs as? NSNumber {
            // Distinguish Int vs Double encodings — NSNumber isEqual would
            // otherwise treat Int(10) and Double(10.0) as equal.
            if String(cString: lNum.objCType) != String(cString: rNum.objCType) {
                return false
            }
            return lNum.isEqual(rNum)
        }
        if (lhs is NSNumber) || (rhs is NSNumber) {
            return false
        }
        if let lInt = lhs as? Int, let rInt = rhs as? Int {
            return lInt == rInt
        }
        if (lhs is Int) || (rhs is Int) {
            return false
        }
        if let lDouble = lhs as? Double, let rDouble = rhs as? Double {
            return lDouble == rDouble
        }
        if (lhs is Double) || (rhs is Double) {
            return false
        }
        if let lInt64 = lhs as? Int64, let rInt64 = rhs as? Int64 {
            return lInt64 == rInt64
        }
        if (lhs is Int64) || (rhs is Int64) {
            return false
        }
        return nil
    }

    private func ckArrayEquality(_ lhs: Any, _ rhs: Any) -> Bool? {
        if let lArr = lhs as? NSArray, let rArr = rhs as? NSArray {
            guard lArr.count == rArr.count else { return false }
            for index in 0 ..< lArr.count
                where !ckArrayElementsEqual(lArr[index], rArr[index])
            {
                return false
            }
            return true
        }
        if (lhs is NSArray) || (rhs is NSArray) {
            return false
        }
        return nil
    }

    private func ckStringEquality(_ lhs: Any, _ rhs: Any) -> Bool? {
        if let lStr = lhs as? String, let rStr = rhs as? String {
            return lStr == rStr
        }
        if (lhs is String) || (rhs is String) {
            return false
        }
        return nil
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
            let expectedActiveZone = appState?.familyZoneID
            if let backgroundCache {
                await backgroundCache.deleteByIdentity(
                    identity,
                    type: cachedType,
                    expectedActiveZone: expectedActiveZone
                )
            } else {
                // No background writer (in-memory stores): fall back to the
                // legacy main-actor invalidation so deletions still apply.
                await cacheService?.invalidate(
                    identity: identity,
                    type: cachedType,
                    expectedActiveZone: expectedActiveZone
                )
            }
        }
    }
}
