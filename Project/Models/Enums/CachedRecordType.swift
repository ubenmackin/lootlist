//
//  CachedRecordType.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os
import SwiftData

enum CachedRecordType: String, CaseIterable, Sendable {
    case profile
    case family
    case quest
    case questTemplate
    case questCompletion
    case ledgerEntry
    case allowancePeriod
    case achievement
    case profileAchievement
    case notificationPreference
    case gemLedger
    case rewardEvent
    case goal

    // MARK: - Scope Split

    /// Database scopes from which this record type can be fetched. All family-zone types are logically
    /// zone-bound and exist in both the owner's private database and the participant's shared database.
    var fetchScopes: Set<CKDatabase.Scope> {
        // Currently every family-zone type is fetchable from both scopes; the distinction is which DB holds
        // the active zone.
        [.private, .shared]
    }

    /// Convenience for the common case: required scope is the active zone's DB.
    static func requiredScope(isZoneOwner: Bool) -> CKDatabase.Scope {
        DatabaseScopeResolver.scope(isOwner: isZoneOwner)
    }

    var ckRecordType: CKRecord.RecordType {
        switch self {
        case .profile: Profile.recordType
        case .family: Family.recordType
        case .quest: Quest.recordType
        case .questTemplate: QuestTemplate.recordType
        case .questCompletion: QuestCompletion.recordType
        case .ledgerEntry: LedgerEntry.recordType
        case .allowancePeriod: AllowancePeriod.recordType
        case .achievement: Achievement.recordType
        case .profileAchievement: ProfileAchievement.recordType
        case .notificationPreference: NotificationPreference.recordType
        case .gemLedger: GemLedger.recordType
        case .rewardEvent: RewardEvent.recordType
        case .goal: Goal.recordType
        }
    }

    static func recordType(for ckRecordType: CKRecord.RecordType) -> CachedRecordType? {
        allCases.first { $0.ckRecordType == ckRecordType }
    }
}

extension CachedRecordType {
    private static let deletionLogger = Logger(category: "CacheDeletion")

    /// WHY single source: one table vends all typed deletions so new cases cannot drift across actors.
    private struct DeletionDispatch {
        let deleteByIdentity: (ModelContext, ScopedRecordIdentity, CKRecordZone.ID?) -> Void
        let deleteByName: (ModelContext, String, String) -> Void
        let purgeMissing: (ModelContext, Set<String>, String?, Set<String>) -> Void
    }

    private var deletionDispatch: DeletionDispatch {
        switch self {
        case .profile: DeletionDispatch(
                deleteByIdentity: { Self.deleteSingleByIdentity(ProfileCache.self, in: $0, identity: $1, expectedActiveZone: $2) },
                deleteByName: { Self.deleteScopedByName(ProfileCache.self, in: $0, recordName: $1, familyRecordName: $2) },
                purgeMissing: { Self.purgeRows(ProfileCache.self, in: $0, validRecordNames: $1, familyRecordName: $2, preservedRecordNames: $3) }
            )
        case .family: DeletionDispatch(
                deleteByIdentity: { Self.deleteSingleByIdentity(FamilyCache.self, in: $0, identity: $1, expectedActiveZone: $2) },
                deleteByName: { context, recordName, _ in Self.deleteFamilyByName(in: context, recordName: recordName) },
                purgeMissing: { Self.purgeRows(FamilyCache.self, in: $0, validRecordNames: $1, familyRecordName: $2, preservedRecordNames: $3) }
            )
        case .quest: DeletionDispatch(
                deleteByIdentity: { Self.deleteSingleByIdentity(QuestCache.self, in: $0, identity: $1, expectedActiveZone: $2) },
                deleteByName: { Self.deleteScopedByName(QuestCache.self, in: $0, recordName: $1, familyRecordName: $2) },
                purgeMissing: { Self.purgeRows(QuestCache.self, in: $0, validRecordNames: $1, familyRecordName: $2, preservedRecordNames: $3) }
            )
        case .questTemplate: DeletionDispatch(
                deleteByIdentity: { Self.deleteSingleByIdentity(QuestTemplateCache.self, in: $0, identity: $1, expectedActiveZone: $2) },
                deleteByName: { Self.deleteScopedByName(QuestTemplateCache.self, in: $0, recordName: $1, familyRecordName: $2) },
                purgeMissing: { Self.purgeRows(QuestTemplateCache.self, in: $0, validRecordNames: $1, familyRecordName: $2, preservedRecordNames: $3) }
            )
        case .questCompletion: DeletionDispatch(
                deleteByIdentity: { Self.deleteSingleByIdentity(QuestCompletionCache.self, in: $0, identity: $1, expectedActiveZone: $2) },
                deleteByName: { Self.deleteScopedByName(QuestCompletionCache.self, in: $0, recordName: $1, familyRecordName: $2) },
                purgeMissing: { Self.purgeRows(QuestCompletionCache.self, in: $0, validRecordNames: $1, familyRecordName: $2, preservedRecordNames: $3) }
            )
        case .ledgerEntry: DeletionDispatch(
                deleteByIdentity: { Self.deleteSingleByIdentity(LedgerEntryCache.self, in: $0, identity: $1, expectedActiveZone: $2) },
                deleteByName: { Self.deleteScopedByName(LedgerEntryCache.self, in: $0, recordName: $1, familyRecordName: $2) },
                purgeMissing: { Self.purgeRows(LedgerEntryCache.self, in: $0, validRecordNames: $1, familyRecordName: $2, preservedRecordNames: $3) }
            )
        case .allowancePeriod: DeletionDispatch(
                deleteByIdentity: { Self.deleteSingleByIdentity(AllowancePeriodCache.self, in: $0, identity: $1, expectedActiveZone: $2) },
                deleteByName: { Self.deleteScopedByName(AllowancePeriodCache.self, in: $0, recordName: $1, familyRecordName: $2) },
                purgeMissing: { Self.purgeRows(AllowancePeriodCache.self, in: $0, validRecordNames: $1, familyRecordName: $2, preservedRecordNames: $3) }
            )
        case .achievement: DeletionDispatch(
                deleteByIdentity: { Self.deleteSingleByIdentity(AchievementCache.self, in: $0, identity: $1, expectedActiveZone: $2) },
                deleteByName: { Self.deleteScopedByName(AchievementCache.self, in: $0, recordName: $1, familyRecordName: $2) },
                purgeMissing: { Self.purgeRows(AchievementCache.self, in: $0, validRecordNames: $1, familyRecordName: $2, preservedRecordNames: $3) }
            )
        case .profileAchievement: DeletionDispatch(
                deleteByIdentity: { Self.deleteSingleByIdentity(ProfileAchievementCache.self, in: $0, identity: $1, expectedActiveZone: $2) },
                deleteByName: { Self.deleteScopedByName(ProfileAchievementCache.self, in: $0, recordName: $1, familyRecordName: $2) },
                purgeMissing: { Self.purgeRows(ProfileAchievementCache.self, in: $0, validRecordNames: $1, familyRecordName: $2, preservedRecordNames: $3) }
            )
        case .notificationPreference: DeletionDispatch(
                deleteByIdentity: { Self.deleteSingleByIdentity(NotificationPreferenceCache.self, in: $0, identity: $1, expectedActiveZone: $2) },
                deleteByName: { Self.deleteScopedByName(NotificationPreferenceCache.self, in: $0, recordName: $1, familyRecordName: $2) },
                purgeMissing: { Self.purgeRows(NotificationPreferenceCache.self, in: $0, validRecordNames: $1, familyRecordName: $2, preservedRecordNames: $3) }
            )
        case .gemLedger: DeletionDispatch(
                deleteByIdentity: { Self.deleteSingleByIdentity(GemLedgerCache.self, in: $0, identity: $1, expectedActiveZone: $2) },
                deleteByName: { Self.deleteScopedByName(GemLedgerCache.self, in: $0, recordName: $1, familyRecordName: $2) },
                purgeMissing: { Self.purgeRows(GemLedgerCache.self, in: $0, validRecordNames: $1, familyRecordName: $2, preservedRecordNames: $3) }
            )
        case .rewardEvent: DeletionDispatch(
                deleteByIdentity: { Self.deleteSingleByIdentity(RewardEventCache.self, in: $0, identity: $1, expectedActiveZone: $2) },
                deleteByName: { Self.deleteScopedByName(RewardEventCache.self, in: $0, recordName: $1, familyRecordName: $2) },
                purgeMissing: { Self.purgeRows(RewardEventCache.self, in: $0, validRecordNames: $1, familyRecordName: $2, preservedRecordNames: $3) }
            )
        case .goal: DeletionDispatch(
                deleteByIdentity: { Self.deleteSingleByIdentity(GoalCache.self, in: $0, identity: $1, expectedActiveZone: $2) },
                deleteByName: { Self.deleteScopedByName(GoalCache.self, in: $0, recordName: $1, familyRecordName: $2) },
                purgeMissing: { Self.purgeRows(GoalCache.self, in: $0, validRecordNames: $1, familyRecordName: $2, preservedRecordNames: $3) }
            )
        }
    }

    /// WHY shared entry: both actors route typed deletes here so zone checks never drift.
    func deleteByIdentity(in context: ModelContext, identity: ScopedRecordIdentity, expectedActiveZone: CKRecordZone.ID?) {
        deletionDispatch.deleteByIdentity(context, identity, expectedActiveZone)
    }

    /// WHY shared entry: name deletes stay family-scoped without per-actor switches.
    func deleteByNameAndFamily(in context: ModelContext, recordName: String, familyRecordName: String) {
        deletionDispatch.deleteByName(context, recordName, familyRecordName)
    }

    /// WHY shared entry: reconciliation prunes via one table so empty-type purges stay legitimate.
    func purgeMissing(in context: ModelContext, validRecordNames: Set<String>, familyRecordName: String?, preservedRecordNames: Set<String> = []) {
        deletionDispatch.purgeMissing(context, validRecordNames, familyRecordName, preservedRecordNames)
    }

    /// WHY fail-closed: scoped delete without family must not scan other families.
    static func deleteSingleByIdentity<T: CacheMergeable>(_ type: T.Type, in context: ModelContext, identity: ScopedRecordIdentity, expectedActiveZone: CKRecordZone.ID?) {
        let recordName = identity.recordID.recordName
        let match: T?
        do {
            if let expectedFamily = identity.familyRecordName, !expectedFamily.isEmpty {
                match = try context.fetch(type.fetchDescriptor(recordName: recordName, familyRecordName: expectedFamily)).first
            } else if let familyType = type as? FamilyCache.Type {
                // WHY root exception: family is the partition so recordName-only lookup stays valid.
                match = try context.fetch(familyType.fetchDescriptor(recordName: recordName)).first as? T
            } else {
                return
            }
        } catch {
            deletionLogger.warning("Failed to fetch \(recordName, privacy: .private) for identity deletion: \(error, privacy: .private)")
            return
        }
        guard let match else { return }
        if let expectedFamily = identity.familyRecordName, let scoped = match as? any FamilyScopedCache {
            guard scoped.familyRecordName == expectedFamily else {
                deletionLogger
                    .warning(
                        "Cache deletion aborted for \(recordName, privacy: .private): expected family \(expectedFamily, privacy: .private), found \(scoped.familyRecordName, privacy: .private)"
                    )
                return
            }
        }
        if let scoped = match as? any FamilyScopedCache, let sourceZone = scoped.sourceZoneName,
           identity.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName, sourceZone != identity.zoneID.zoneName
        {
            let isFamilyMatch: Bool = {
                guard let expectedFamily = identity.familyRecordName else { return false }
                return scoped.familyRecordName == expectedFamily
            }()
            let isActiveZone = expectedActiveZone.map { $0 == identity.zoneID } ?? false
            if isFamilyMatch, isActiveZone {
                deletionLogger.info("Orphan row \(recordName, privacy: .private) zone switch \(sourceZone, privacy: .private)->\(identity.zoneID.zoneName, privacy: .private)")
            } else {
                deletionLogger
                    .warning(
                        "Cache deletion aborted for \(recordName, privacy: .private): expected zone \(identity.zoneID.zoneName, privacy: .private), found \(sourceZone, privacy: .private)"
                    )
                return
            }
        }
        context.delete(match)
    }

    /// WHY indexed probe: recordName+family rides the composite index, never scans the family table.
    static func deleteScopedByName<T: CacheMergeable & FamilyScopedCache>(_ type: T.Type, in context: ModelContext, recordName: String, familyRecordName: String) {
        do {
            for match in try context.fetch(type.fetchDescriptor(recordName: recordName, familyRecordName: familyRecordName)) {
                context.delete(match)
            }
        } catch {
            deletionLogger.warning("Failed to fetch \(T.self, privacy: .public) for invalidation: \(error, privacy: .private)")
        }
    }

    /// WHY root exception: family is the partition so recordName-only lookup stays valid here.
    static func deleteFamilyByName(in context: ModelContext, recordName: String) {
        do {
            if let match = try context.fetch(FamilyCache.fetchDescriptor(recordName: recordName)).first {
                context.delete(match)
            }
        } catch {
            deletionLogger.warning("Failed to fetch FamilyCache for invalidation: \(error, privacy: .private)")
        }
    }

    /// WHY preserved union: unacked rows absent server-side survive while acked deletions still prune.
    static func purgeRows<T: CacheMergeable>(
        _ type: T.Type,
        in context: ModelContext,
        validRecordNames: Set<String>,
        familyRecordName: String?,
        preservedRecordNames: Set<String> = []
    ) {
        var effective = validRecordNames
        effective.formUnion(preservedRecordNames)
        let family: String?
        if type == FamilyCache.self {
            family = nil
        } else {
            guard let validated = familyRecordName, !validated.isEmpty else {
                deletionLogger.warning("Purge skipped: familyRecordName is required, got nil/empty scope")
                return
            }
            family = validated
        }
        let existing: [T]
        do {
            existing = try context.fetch(type.fetchDescriptor(familyRecordName: family))
        } catch {
            deletionLogger.error("Failed to fetch existing \(T.self, privacy: .private) for purgeMissing: \(error, privacy: .private)")
            return
        }
        for cached in existing where !effective.contains(cached.recordName) {
            context.delete(cached)
        }
    }
}
