//
//  RecordBridge.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CloudKit
import Foundation
import os
import SwiftData

/// Bridges SwiftData cache models to CKRecords for CKSyncEngine synchronization.
@MainActor
enum RecordBridge {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "RecordBridge"
    )

    static func record(for identity: ScopedRecordIdentity, cacheService: CacheService) -> CKRecord? {
        guard let familyRecordName = identity.familyRecordName else {
            logger.warning("RecordBridge aborted: ScopedRecordIdentity has no familyRecordName for recordID=\(identity.recordID.recordName, privacy: .private)")
            return nil
        }
        let name = identity.recordName
        let zoneID = identity.zoneID
        let scope = identity.databaseScope
        for type in CachedRecordType.allCases {
            if let ck = resolvedRecord(for: type, name: name, zoneID: zoneID, cacheService: cacheService, expectedFamily: familyRecordName, expectedDatabase: scope) {
                return prepareRecord(ck, in: zoneID)
            }
        }
        logger.warning("RecordBridge could not find cached entity for recordID=\(name, privacy: .private)")
        return nil
    }

    /// Confirms local deletion across all cache tables before enqueuing server delete.
    /// Fails closed on lookup errors to retain pending saves until deletion is verified.
    static func confirmedLocalDeletion(for identity: ScopedRecordIdentity, cacheService: CacheService) -> Bool {
        switch deletionCheckResult(for: identity, cacheService: cacheService) {
        case .confirmed:
            return true
        case .stillPresent:
            return false
        case .unknown:
            // WHY: fetch failed — retain pending save for retry.
            logger.fault("RecordBridge confirmedLocalDeletion unknown — fetch threw for \(identity.recordName, privacy: .private); retaining pending save for retry")
            return false
        }
    }

    /// WHY: distinguishes present row from fetch error so caller can retry without dropping delete.
    static func fetchSucceeded(for identity: ScopedRecordIdentity, cacheService: CacheService) -> Bool {
        deletionCheckResult(for: identity, cacheService: cacheService) != .unknown
    }

    /// Tri-state result — prevents stall where `tryFetch == nil` was collapsed to `false` and retained pending save indefinitely without retry.
    private enum DeletionCheckResult {
        case confirmed
        case stillPresent
        case unknown
    }

    private static func deletionCheckResult(for identity: ScopedRecordIdentity, cacheService: CacheService) -> DeletionCheckResult {
        let name = identity.recordName
        var allAbsent = true
        // WHY: fail closed — any fetch error returns .unknown for retry.
        for type in CachedRecordType.allCases {
            guard let result = deletionStatus(for: type, name: name, cacheService: cacheService) else {
                continue
            }
            if result == .unknown {
                return .unknown
            }
            allAbsent = false
        }
        return allAbsent ? .confirmed : .stillPresent
    }

    /// Generic helper — single predicate source for existence checks.
    /// Returns `.stillPresent` if a row exists, `nil` if absent, `.unknown` if the fetch threw.
    private static func fetchExists(_ type: (some CacheMergeable).Type, name: String, cacheService: CacheService) -> DeletionCheckResult? {
        guard let rows = cacheService.tryFetch(type.fetchDescriptor(recordName: name)) else {
            return .unknown
        }
        return rows.first != nil ? .stillPresent : nil
    }

    private static func deletionStatus(for type: CachedRecordType, name: String, cacheService: CacheService) -> DeletionCheckResult? {
        switch type {
        case .family: fetchExists(FamilyCache.self, name: name, cacheService: cacheService)
        case .profile: fetchExists(ProfileCache.self, name: name, cacheService: cacheService)
        case .quest: fetchExists(QuestCache.self, name: name, cacheService: cacheService)
        case .questTemplate: fetchExists(QuestTemplateCache.self, name: name, cacheService: cacheService)
        case .questCompletion: fetchExists(QuestCompletionCache.self, name: name, cacheService: cacheService)
        case .ledgerEntry: fetchExists(LedgerEntryCache.self, name: name, cacheService: cacheService)
        case .allowancePeriod: fetchExists(AllowancePeriodCache.self, name: name, cacheService: cacheService)
        case .achievement: fetchExists(AchievementCache.self, name: name, cacheService: cacheService)
        case .profileAchievement: fetchExists(ProfileAchievementCache.self, name: name, cacheService: cacheService)
        case .notificationPreference: fetchExists(NotificationPreferenceCache.self, name: name, cacheService: cacheService)
        case .gemLedger: fetchExists(GemLedgerCache.self, name: name, cacheService: cacheService)
        case .rewardEvent: fetchExists(RewardEventCache.self, name: name, cacheService: cacheService)
        case .goal: fetchExists(GoalCache.self, name: name, cacheService: cacheService)
        }
    }

    private static func resolvedRecord(
        for type: CachedRecordType,
        name: String,
        zoneID: CKRecordZone.ID,
        cacheService: CacheService,
        expectedFamily: String,
        expectedDatabase: CKDatabase.Scope
    ) -> CKRecord? {
        if let core = resolveCoreRecord(for: type, name: name, zoneID: zoneID, cacheService: cacheService, expectedFamily: expectedFamily, expectedDatabase: expectedDatabase) {
            return core
        }
        return resolveExtendedRecord(for: type, name: name, zoneID: zoneID, cacheService: cacheService, expectedFamily: expectedFamily, expectedDatabase: expectedDatabase)
    }

    private static func resolveCoreRecord(
        for type: CachedRecordType,
        name: String,
        zoneID: CKRecordZone.ID,
        cacheService: CacheService,
        expectedFamily: String,
        expectedDatabase: CKDatabase.Scope
    ) -> CKRecord? {
        switch type {
        case .quest: bridge(
                QuestCache.self,
                name: name,
                zoneID: zoneID,
                expectedFamily: expectedFamily,
                expectedDatabase: expectedDatabase,
                entity: "quest",
                fetch: { cacheService.fetchQuest(recordName: $0, family: $1) },
                toRecord: { $0.toQuest(zoneID: $1).toRecord() }
            )
        case .questCompletion: bridge(
                QuestCompletionCache.self,
                name: name,
                zoneID: zoneID,
                expectedFamily: expectedFamily,
                expectedDatabase: expectedDatabase,
                entity: "completion",
                fetch: { cacheService.fetchQuestCompletion(recordName: $0, family: $1) },
                toRecord: { $0.toQuestCompletion(zoneID: $1).toRecord() }
            )
        case .questTemplate: bridge(
                QuestTemplateCache.self,
                name: name,
                zoneID: zoneID,
                expectedFamily: expectedFamily,
                expectedDatabase: expectedDatabase,
                entity: "template",
                fetch: { cacheService.fetchQuestTemplate(recordName: $0, family: $1) },
                toRecord: { $0.toQuestTemplate(zoneID: $1).toRecord() }
            )
        case .profile: bridge(
                ProfileCache.self,
                name: name,
                zoneID: zoneID,
                expectedFamily: expectedFamily,
                expectedDatabase: expectedDatabase,
                entity: "profile",
                fetch: { cacheService.fetchProfile(recordName: $0, family: $1) },
                toRecord: { $0.toProfile(zoneID: $1).toRecord() }
            )
        case .family: bridgeFamily(name: name, zoneID: zoneID, cacheService: cacheService, expectedFamily: expectedFamily, expectedDatabase: expectedDatabase)
        case .ledgerEntry: bridge(
                LedgerEntryCache.self,
                name: name,
                zoneID: zoneID,
                expectedFamily: expectedFamily,
                expectedDatabase: expectedDatabase,
                entity: "ledger",
                fetch: { cacheService.fetchLedgerEntry(recordName: $0, family: $1) },
                toRecord: { $0.toLedgerEntry(zoneID: $1).toRecord() }
            )
        case .allowancePeriod: bridge(
                AllowancePeriodCache.self,
                name: name,
                zoneID: zoneID,
                expectedFamily: expectedFamily,
                expectedDatabase: expectedDatabase,
                entity: "allowance",
                fetch: { cacheService.fetchAllowancePeriod(recordName: $0, family: $1) },
                toRecord: { $0.toAllowancePeriod(zoneID: $1).toRecord() }
            )
        default: nil
        }
    }

    private static func resolveExtendedRecord(
        for type: CachedRecordType,
        name: String,
        zoneID: CKRecordZone.ID,
        cacheService: CacheService,
        expectedFamily: String,
        expectedDatabase: CKDatabase.Scope
    ) -> CKRecord? {
        switch type {
        case .achievement: bridge(
                AchievementCache.self,
                name: name,
                zoneID: zoneID,
                expectedFamily: expectedFamily,
                expectedDatabase: expectedDatabase,
                entity: "achievement",
                fetch: { cacheService.fetchAchievement(recordName: $0, family: $1) },
                toRecord: { $0.toAchievement(zoneID: $1).toRecord() }
            )
        case .profileAchievement: bridge(
                ProfileAchievementCache.self,
                name: name,
                zoneID: zoneID,
                expectedFamily: expectedFamily,
                expectedDatabase: expectedDatabase,
                entity: "profile achievement",
                fetch: { cacheService.fetchProfileAchievement(recordName: $0, family: $1) },
                toRecord: { $0.toProfileAchievement(zoneID: $1).toRecord() }
            )
        case .notificationPreference: bridge(
                NotificationPreferenceCache.self,
                name: name,
                zoneID: zoneID,
                expectedFamily: expectedFamily,
                expectedDatabase: expectedDatabase,
                entity: "notification pref",
                fetch: { cacheService.fetchNotificationPreference(recordName: $0, family: $1) },
                toRecord: { $0.toNotificationPreference(zoneID: $1).toRecord() }
            )
        case .gemLedger: bridge(
                GemLedgerCache.self,
                name: name,
                zoneID: zoneID,
                expectedFamily: expectedFamily,
                expectedDatabase: expectedDatabase,
                entity: "gem ledger",
                fetch: { cacheService.fetchGemLedger(recordName: $0, family: $1) },
                toRecord: { $0.toGemLedger(zoneID: $1).toRecord() }
            )
        case .rewardEvent: bridge(
                RewardEventCache.self,
                name: name,
                zoneID: zoneID,
                expectedFamily: expectedFamily,
                expectedDatabase: expectedDatabase,
                entity: "reward event",
                fetch: { cacheService.fetchRewardEvent(recordName: $0, family: $1) },
                toRecord: { $0.toRewardEvent(zoneID: $1).toRecord() }
            )
        case .goal: bridge(
                GoalCache.self,
                name: name,
                zoneID: zoneID,
                expectedFamily: expectedFamily,
                expectedDatabase: expectedDatabase,
                entity: "goal",
                fetch: { cacheService.fetchGoal(recordName: $0, family: $1) },
                toRecord: { $0.toGoal(zoneID: $1).toRecord() }
            )
        default: nil
        }
    }

    private static func validateScopedRecord(
        _ cache: some FamilyScopedCache,
        expectedFamily: String,
        expectedDatabaseScope: CKDatabase.Scope,
        expectedZoneID: CKRecordZone.ID,
        entity: String,
        name: String
    ) -> Bool {
        if cache.familyRecordName != expectedFamily {
            logger.warning(
                "RecordBridge family mismatch for \(entity) \(name) expected \(expectedFamily) got \(cache.familyRecordName)",
                family: expectedFamily,
                zone: expectedZoneID.zoneName
            )
            return false
        }
        if cache.validatedDatabaseScope(expectedScope: expectedDatabaseScope) == nil {
            let isFamilyZoneMatch = cache.sourceZoneName == expectedZoneID.zoneName
            let persisted = cache.sourceDatabaseScope ?? "nil"
            if isFamilyZoneMatch, persisted == "private",
               expectedDatabaseScope == .shared, entity == "completion"
            {
                logger.warning(
                    "RecordBridge database scope mismatch for \(entity) \(name) "
                        + "expected \(String(describing: expectedDatabaseScope)) got \(persisted) "
                        + "— family and zone match verified, allowing bridge for pending-review stall recovery",
                    family: expectedFamily,
                    zone: expectedZoneID.zoneName
                )
                return true
            }
            logger.warning(
                "RecordBridge database scope mismatch for \(entity) \(name) expected \(String(describing: expectedDatabaseScope)) got \(cache.sourceDatabaseScope ?? "nil")",
                family: expectedFamily,
                zone: expectedZoneID.zoneName
            )
            return false
        }
        return true
    }

    private static func bridge<T: FamilyScopedCache & CacheMergeable>(
        _: T.Type,
        name: String,
        zoneID: CKRecordZone.ID,
        expectedFamily: String,
        expectedDatabase: CKDatabase.Scope,
        entity: String,
        fetch: (String, String) -> T?,
        toRecord: (T, CKRecordZone.ID) -> CKRecord
    ) -> CKRecord? {
        guard let cache = fetch(name, expectedFamily) else { return nil }
        guard validateScopedRecord(cache, expectedFamily: expectedFamily, expectedDatabaseScope: expectedDatabase, expectedZoneID: zoneID, entity: entity, name: name)
        else { return nil }
        return toRecord(cache, zoneID)
    }

    private static func bridgeFamily(name: String, zoneID: CKRecordZone.ID, cacheService: CacheService, expectedFamily: String, expectedDatabase: CKDatabase.Scope) -> CKRecord? {
        guard let cache = cacheService.fetchFamily(recordName: name) else { return nil }
        if cache.recordName != expectedFamily {
            logger.warning(
                "RecordBridge family mismatch for family \(name) expected \(expectedFamily) got \(cache.recordName)",
                family: expectedFamily,
                zone: zoneID.zoneName
            )
            return nil
        }
        if cache.validatedDatabaseScope(expectedScope: expectedDatabase) == nil {
            logger.warning(
                "RecordBridge database scope mismatch for family \(name) expected \(String(describing: expectedDatabase)) got \(cache.sourceDatabaseScope ?? "nil")",
                family: expectedFamily,
                zone: zoneID.zoneName
            )
            return nil
        }
        return cache.toFamily(zoneID: zoneID).toRecord()
    }

    private static let managedFieldKeysByType: [String: Set<String>] = [
        Family.recordType: Family.managedFieldKeys,
        Profile.recordType: Profile.managedFieldKeys,
        QuestTemplate.recordType: QuestTemplate.managedFieldKeys,
        Quest.recordType: Quest.managedFieldKeys,
        QuestCompletion.recordType: QuestCompletion.managedFieldKeys,
        AllowancePeriod.recordType: AllowancePeriod.managedFieldKeys,
        LedgerEntry.recordType: LedgerEntry.managedFieldKeys,
        Achievement.recordType: Achievement.managedFieldKeys,
        ProfileAchievement.recordType: ProfileAchievement.managedFieldKeys,
        NotificationPreference.recordType: NotificationPreference.managedFieldKeys,
        RewardEvent.recordType: RewardEvent.managedFieldKeys,
        GemLedger.recordType: GemLedger.managedFieldKeys,
        Goal.recordType: Goal.managedFieldKeys
    ]

    static func logTransferSkewIfNeeded(localDate: Date, serverDate: Date) {
        WeekMath.logTransferSkewIfNeeded(localDate: localDate, serverDate: serverDate)
    }

    static func checkTransferSkew(for record: CKRecord, localEntry: LedgerEntry) {
        guard record.recordType == LedgerEntry.recordType, localEntry.sourceEnum == .transfer else { return }
        let serverDate: Date? = record.creationDate ?? {
            let data = record.encodedSystemFields
            guard !data.isEmpty else { return nil }
            do {
                return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)?.creationDate
            } catch {
                logger.warning("CKRecord systemFields decode failed for \(record.recordID.recordName, privacy: .private): \(error, privacy: .private)")
                return nil
            }
        }()
        guard let serverDate else { return }
        WeekMath.logTransferSkewIfNeeded(localDate: localEntry.date, serverDate: serverDate)
    }

    private static func prepareRecord(_ record: CKRecord, in zoneID: CKRecordZone.ID) -> CKRecord {
        if record.recordType != Family.recordType {
            if let familyRef = record["family"] as? CKRecord.Reference {
                let parentID = CKRecord.ID(recordName: familyRef.recordID.recordName, zoneID: zoneID)
                record.parent = CKRecord.Reference(recordID: parentID, action: .none)
            } else if let parent = record.parent {
                let parentID = CKRecord.ID(recordName: parent.recordID.recordName, zoneID: zoneID)
                record.parent = CKRecord.Reference(recordID: parentID, action: .none)
            }
        }

        // Explicitly clear omitted managed fields so CloudKit deletes them from the server record
        if let managedKeys = managedFieldKeysByType[record.recordType] {
            let presentKeys = Set(record.allKeys())
            for key in managedKeys where !presentKeys.contains(key) {
                record[key] = nil
            }
        }

        return record
    }
}

private extension Logger {
    func warning(_ message: String, family: String, zone: String) {
        log(level: .default, "\(message, privacy: .public) family=\(family, privacy: .private) zone=\(zone, privacy: .private)")
    }

    func info(_ message: String, family: String, zone: String) {
        log(level: .info, "\(message, privacy: .public) family=\(family, privacy: .private) zone=\(zone, privacy: .private)")
    }

    func error(_ message: String, family: String, zone: String) {
        log(level: .error, "\(message, privacy: .public) family=\(family, privacy: .private) zone=\(zone, privacy: .private)")
    }
}
