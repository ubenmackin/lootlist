//
//  RecordBridge.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CloudKit
import Foundation
import os

/// Bridges local SwiftData cached models to CloudKit `CKRecord` objects
/// when `CKSyncEngine` requests record batches to send to the server.
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

        let expectedScope = identity.databaseScope
        let bridges: [() -> CKRecord?] = [
            { bridgeQuest(name: name, zoneID: zoneID, cacheService: cacheService, expectedFamily: familyRecordName, expectedDatabase: expectedScope) },
            { bridgeQuestCompletion(name: name, zoneID: zoneID, cacheService: cacheService, expectedFamily: familyRecordName, expectedDatabase: expectedScope) },
            { bridgeQuestTemplate(name: name, zoneID: zoneID, cacheService: cacheService, expectedFamily: familyRecordName, expectedDatabase: expectedScope) },
            { bridgeProfile(name: name, zoneID: zoneID, cacheService: cacheService, expectedFamily: familyRecordName, expectedDatabase: expectedScope) },
            { bridgeFamily(name: name, zoneID: zoneID, cacheService: cacheService, expectedFamily: familyRecordName, expectedDatabase: expectedScope) },
            { bridgeLedger(name: name, zoneID: zoneID, cacheService: cacheService, expectedFamily: familyRecordName, expectedDatabase: expectedScope) },
            { bridgeAllowance(name: name, zoneID: zoneID, cacheService: cacheService, expectedFamily: familyRecordName, expectedDatabase: expectedScope) },
            { bridgeAchievement(name: name, zoneID: zoneID, cacheService: cacheService, expectedFamily: familyRecordName, expectedDatabase: expectedScope) },
            { bridgeProfileAchievement(name: name, zoneID: zoneID, cacheService: cacheService, expectedFamily: familyRecordName, expectedDatabase: expectedScope) },
            { bridgeNotificationPref(name: name, zoneID: zoneID, cacheService: cacheService, expectedFamily: familyRecordName, expectedDatabase: expectedScope) },
            { bridgeGemLedger(name: name, zoneID: zoneID, cacheService: cacheService, expectedFamily: familyRecordName, expectedDatabase: expectedScope) },
            { bridgeRewardEvent(name: name, zoneID: zoneID, cacheService: cacheService, expectedFamily: familyRecordName, expectedDatabase: expectedScope) }
        ]

        for bridge in bridges {
            if let ckRecord = bridge() {
                return prepareRecord(ckRecord, in: zoneID)
            }
        }

        logger.warning("RecordBridge could not find cached entity for recordID=\(name, privacy: .private)")
        return nil
    }

    private static func validateScopedRecord(
        _ cache: some FamilyScopedCache,
        expectedFamily: String,
        expectedDatabaseScope: CKDatabase.Scope,
        entity: String,
        name: String
    ) -> Bool {
        if cache.familyRecordName != expectedFamily {
            logger.warning("RecordBridge family mismatch for \(entity) \(name): expected \(expectedFamily), got \(cache.familyRecordName)")
            return false
        }
        if cache.validatedDatabaseScope(expectedScope: expectedDatabaseScope) == nil {
            logger
                .warning(
                    "RecordBridge database scope mismatch for \(entity) \(name): expected \(String(describing: expectedDatabaseScope)), got \(cache.sourceDatabaseScope ?? "nil")"
                )
            return false
        }
        return true
    }

    private static func bridgeQuest(name: String, zoneID: CKRecordZone.ID, cacheService: CacheService, expectedFamily: String, expectedDatabase: CKDatabase.Scope) -> CKRecord? {
        guard let cache = cacheService.fetchQuest(recordName: name, family: expectedFamily) else { return nil }
        guard validateScopedRecord(cache, expectedFamily: expectedFamily, expectedDatabaseScope: expectedDatabase, entity: "quest", name: name) else { return nil }
        return cache.toQuest(zoneID: zoneID).toRecord()
    }

    private static func bridgeQuestCompletion(name: String, zoneID: CKRecordZone.ID, cacheService: CacheService, expectedFamily: String,
                                              expectedDatabase: CKDatabase.Scope) -> CKRecord?
    {
        guard let cache = cacheService.fetchQuestCompletion(recordName: name, family: expectedFamily) else { return nil }
        guard validateScopedRecord(cache, expectedFamily: expectedFamily, expectedDatabaseScope: expectedDatabase, entity: "completion", name: name) else { return nil }
        return cache.toQuestCompletion(zoneID: zoneID).toRecord()
    }

    private static func bridgeQuestTemplate(name: String, zoneID: CKRecordZone.ID, cacheService: CacheService, expectedFamily: String,
                                            expectedDatabase: CKDatabase.Scope) -> CKRecord?
    {
        guard let cache = cacheService.fetchQuestTemplate(recordName: name, family: expectedFamily) else { return nil }
        guard validateScopedRecord(cache, expectedFamily: expectedFamily, expectedDatabaseScope: expectedDatabase, entity: "template", name: name) else { return nil }
        return cache.toQuestTemplate(zoneID: zoneID).toRecord()
    }

    private static func bridgeProfile(name: String, zoneID: CKRecordZone.ID, cacheService: CacheService, expectedFamily: String, expectedDatabase: CKDatabase.Scope) -> CKRecord? {
        guard let cache = cacheService.fetchProfile(recordName: name, family: expectedFamily) else { return nil }
        guard validateScopedRecord(cache, expectedFamily: expectedFamily, expectedDatabaseScope: expectedDatabase, entity: "profile", name: name) else { return nil }
        return cache.toProfile(zoneID: zoneID).toRecord()
    }

    private static func bridgeFamily(name: String, zoneID: CKRecordZone.ID, cacheService: CacheService, expectedFamily: String, expectedDatabase: CKDatabase.Scope) -> CKRecord? {
        guard let cache = cacheService.fetchFamily(recordName: name) else { return nil }
        if cache.recordName != expectedFamily {
            logger.warning("RecordBridge family mismatch for family \(name): expected \(expectedFamily), got \(cache.recordName)")
            return nil
        }
        if cache.validatedDatabaseScope(expectedScope: expectedDatabase) == nil {
            logger.warning("RecordBridge database scope mismatch for family \(name): expected \(String(describing: expectedDatabase)), got \(cache.sourceDatabaseScope ?? "nil")")
            return nil
        }
        return cache.toFamily(zoneID: zoneID).toRecord()
    }

    private static func bridgeLedger(name: String, zoneID: CKRecordZone.ID, cacheService: CacheService, expectedFamily: String, expectedDatabase: CKDatabase.Scope) -> CKRecord? {
        guard let cache = cacheService.fetchLedgerEntry(recordName: name, family: expectedFamily) else { return nil }
        guard validateScopedRecord(cache, expectedFamily: expectedFamily, expectedDatabaseScope: expectedDatabase, entity: "ledger", name: name) else { return nil }
        return cache.toLedgerEntry(zoneID: zoneID).toRecord()
    }

    private static func bridgeAllowance(name: String, zoneID: CKRecordZone.ID, cacheService: CacheService, expectedFamily: String,
                                        expectedDatabase: CKDatabase.Scope) -> CKRecord?
    {
        guard let cache = cacheService.fetchAllowancePeriod(recordName: name, family: expectedFamily) else { return nil }
        guard validateScopedRecord(cache, expectedFamily: expectedFamily, expectedDatabaseScope: expectedDatabase, entity: "allowance", name: name) else { return nil }
        return cache.toAllowancePeriod(zoneID: zoneID).toRecord()
    }

    private static func bridgeAchievement(name: String, zoneID: CKRecordZone.ID, cacheService: CacheService, expectedFamily: String,
                                          expectedDatabase: CKDatabase.Scope) -> CKRecord?
    {
        guard let cache = cacheService.fetchAchievement(recordName: name, family: expectedFamily) else { return nil }
        guard validateScopedRecord(cache, expectedFamily: expectedFamily, expectedDatabaseScope: expectedDatabase, entity: "achievement", name: name) else { return nil }
        return cache.toAchievement(zoneID: zoneID).toRecord()
    }

    private static func bridgeProfileAchievement(name: String, zoneID: CKRecordZone.ID, cacheService: CacheService, expectedFamily: String,
                                                 expectedDatabase: CKDatabase.Scope) -> CKRecord?
    {
        guard let cache = cacheService.fetchProfileAchievement(recordName: name, family: expectedFamily) else { return nil }
        guard validateScopedRecord(cache, expectedFamily: expectedFamily, expectedDatabaseScope: expectedDatabase, entity: "profile achievement", name: name) else { return nil }
        return cache.toProfileAchievement(zoneID: zoneID).toRecord()
    }

    private static func bridgeNotificationPref(name: String, zoneID: CKRecordZone.ID, cacheService: CacheService, expectedFamily: String,
                                               expectedDatabase: CKDatabase.Scope) -> CKRecord?
    {
        guard let cache = cacheService.fetchNotificationPreference(recordName: name, family: expectedFamily) else { return nil }
        guard validateScopedRecord(cache, expectedFamily: expectedFamily, expectedDatabaseScope: expectedDatabase, entity: "notification pref", name: name) else { return nil }
        return cache.toNotificationPreference(zoneID: zoneID).toRecord()
    }

    private static func bridgeGemLedger(name: String, zoneID: CKRecordZone.ID, cacheService: CacheService, expectedFamily: String,
                                        expectedDatabase: CKDatabase.Scope) -> CKRecord?
    {
        guard let cache = cacheService.fetchGemLedger(recordName: name, family: expectedFamily) else { return nil }
        guard validateScopedRecord(cache, expectedFamily: expectedFamily, expectedDatabaseScope: expectedDatabase, entity: "gem ledger", name: name) else { return nil }
        return cache.toGemLedger(zoneID: zoneID).toRecord()
    }

    private static func bridgeRewardEvent(name: String, zoneID: CKRecordZone.ID, cacheService: CacheService, expectedFamily: String,
                                          expectedDatabase: CKDatabase.Scope) -> CKRecord?
    {
        guard let cache = cacheService.fetchRewardEvent(recordName: name, family: expectedFamily) else { return nil }
        guard validateScopedRecord(cache, expectedFamily: expectedFamily, expectedDatabaseScope: expectedDatabase, entity: "reward event", name: name) else { return nil }
        return cache.toRewardEvent(zoneID: zoneID).toRecord()
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
        GemLedger.recordType: GemLedger.managedFieldKeys
    ]

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
