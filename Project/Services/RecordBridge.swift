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
        let scope = identity.databaseScope
        for type in CachedRecordType.allCases {
            if let ck = resolvedRecord(for: type, name: name, zoneID: zoneID, cacheService: cacheService, expectedFamily: familyRecordName, expectedDatabase: scope) {
                return prepareRecord(ck, in: zoneID)
            }
        }
        logger.warning("RecordBridge could not find cached entity for recordID=\(name, privacy: .private)")
        return nil
    }

    /// Returns true only when no cached row exists for the record name across
    /// every cache table — i.e., local deletion is confirmed. Lookups are
    /// deliberately family- and database-scope-agnostic. The check is
    /// FAIL-CLOSED: each table lookup must complete successfully and find no
    /// row before a server-side delete may be enqueued. A nil result from
    /// `record(for:)` alone proves nothing — family validation, scope
    /// validation (locally-created rows are never hydrated with
    /// `sourceDatabaseScope`), or a cache fetch failure can all produce it —
    /// so any unavailable context or thrown fetch aborts confirmation here
    /// and returns false (treat as NOT deleted). A cache error must never be
    /// misread as "row absent", which would destroy a live cloud record.
    static func confirmedLocalDeletion(for identity: ScopedRecordIdentity, cacheService: CacheService) -> Bool {
        let name = identity.recordName

        /// Returns true only when the lookup itself succeeded AND found no row.
        func confirmedAbsent<T: PersistentModel>(_ type: T.Type, predicate: Predicate<T>) -> Bool {
            guard let rows = cacheService.tryFetch(type, predicate: predicate) else { return false }
            return rows.first == nil
        }

        return confirmedAbsent(FamilyCache.self, predicate: #Predicate { $0.recordName == name })
            && confirmedAbsent(ProfileCache.self, predicate: #Predicate { $0.recordName == name })
            && confirmedAbsent(QuestCache.self, predicate: #Predicate { $0.recordName == name })
            && confirmedAbsent(QuestTemplateCache.self, predicate: #Predicate { $0.recordName == name })
            && confirmedAbsent(QuestCompletionCache.self, predicate: #Predicate { $0.recordName == name })
            && confirmedAbsent(LedgerEntryCache.self, predicate: #Predicate { $0.recordName == name })
            && confirmedAbsent(AllowancePeriodCache.self, predicate: #Predicate { $0.recordName == name })
            && confirmedAbsent(AchievementCache.self, predicate: #Predicate { $0.recordName == name })
            && confirmedAbsent(ProfileAchievementCache.self, predicate: #Predicate { $0.recordName == name })
            && confirmedAbsent(NotificationPreferenceCache.self, predicate: #Predicate { $0.recordName == name })
            && confirmedAbsent(GemLedgerCache.self, predicate: #Predicate { $0.recordName == name })
            && confirmedAbsent(RewardEventCache.self, predicate: #Predicate { $0.recordName == name })
            && confirmedAbsent(GoalCache.self, predicate: #Predicate { $0.recordName == name })
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
            logger
                .warning(
                    """
                    RecordBridge family mismatch for \(entity, privacy: .public) \(name, privacy: .private): \
                    expected \(expectedFamily, privacy: .private), got \(cache.familyRecordName, privacy: .private)
                    """
                )
            return false
        }
        if cache.validatedDatabaseScope(expectedScope: expectedDatabaseScope) == nil {
            // WHY: gated escape hatch for pending-review stall — private Hero completion may bridge to .shared
            // WHY: only for entity == "completion" under strict dual equality: cache.familyRecordName == expectedFamily AND cache.sourceZoneName == expectedZoneID.zoneName (strict non-nil match).
            // Invariant: both familyRecordName and sourceZoneName must match — either mismatch preserves cross-family/cross-zone isolation.
            let isFamilyZoneMatch = cache.sourceZoneName == expectedZoneID.zoneName
            let persisted = cache.sourceDatabaseScope ?? "nil"
            if isFamilyZoneMatch, persisted == "private",
               expectedDatabaseScope == .shared, entity == "completion"
            {
                logger
                    .warning(
                        """
                        RecordBridge database scope mismatch for \
                        \(entity, privacy: .public) \(name, privacy: .private): \
                        expected \(String(describing: expectedDatabaseScope), privacy: .public), \
                        got \(persisted, privacy: .private) — family and zone match verified, \
                        allowing bridge for pending-review stall recovery
                        """
                    )
                return true
            }
            logger
                .warning(
                    """
                    RecordBridge database scope mismatch for \(entity, privacy: .public) \(name, privacy: .private): \
                    expected \(String(describing: expectedDatabaseScope), privacy: .public), \
                    got \(cache.sourceDatabaseScope ?? "nil", privacy: .private)
                    """
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

    // WHY: FamilyCache exception — zone-root record, no zone-scoped dual match; family identity suffices, sourceZoneName not checked.
    private static func bridgeFamily(name: String, zoneID: CKRecordZone.ID, cacheService: CacheService, expectedFamily: String, expectedDatabase: CKDatabase.Scope) -> CKRecord? {
        guard let cache = cacheService.fetchFamily(recordName: name) else { return nil }
        if cache.recordName != expectedFamily {
            logger
                .warning(
                    "RecordBridge family mismatch for family \(name, privacy: .private): expected \(expectedFamily, privacy: .private), got \(cache.recordName, privacy: .private)"
                )
            return nil
        }
        if cache.validatedDatabaseScope(expectedScope: expectedDatabase) == nil {
            logger
                .warning(
                    """
                    RecordBridge database scope mismatch for family \(name, privacy: .private): \
                    expected \(String(describing: expectedDatabase), privacy: .public), \
                    got \(cache.sourceDatabaseScope ?? "nil", privacy: .private)
                    """
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
        // WHY: Single centralized skew helper lives in WeekMath; RecordBridge forwards to keep one warning string.
        WeekMath.logTransferSkewIfNeeded(localDate: localDate, serverDate: serverDate)
    }

    static func checkTransferSkew(for record: CKRecord, localEntry: LedgerEntry) {
        guard record.recordType == LedgerEntry.recordType, localEntry.source == "transfer" else { return }
        let serverDate: Date? = record.creationDate ?? {
            let data = record.encodedSystemFields
            guard !data.isEmpty else { return nil }
            return (try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data))?.creationDate
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
