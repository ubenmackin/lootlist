//
//  CacheService+Invalidation.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

extension CacheService {
    private var currentActiveFamilyZoneID: CKRecordZone.ID? {
        guard let zoneName = defaults.string(forKey: "session_familyZoneName"),
              let ownerName = defaults.string(forKey: "session_familyZoneOwnerName")
        else { return nil }
        return CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
    }

    func deleteAll<T: PersistentModel>(from context: ModelContext?, where predicate: Predicate<T>) {
        guard let context else { return }
        do {
            let items = try context.fetch(FetchDescriptor<T>(predicate: predicate))
            for item in items {
                context.delete(item)
            }
        } catch {
            logger.error("Failed to fetch \(T.self, privacy: .public) for deleteAll: \(error, privacy: .private)")
        }
    }

    /// Single invalidation entry — routes all deletes through one switch.
    func invalidate(identity: ScopedRecordIdentity, type: CachedRecordType) {
        guard let context else { return }
        switch type {
        case .profile: deleteByIdentity(ProfileCache.self, identity: identity, in: context)
        case .family: deleteByIdentity(FamilyCache.self, identity: identity, in: context)
        case .quest: deleteByIdentity(QuestCache.self, identity: identity, in: context)
        case .questTemplate: deleteByIdentity(QuestTemplateCache.self, identity: identity, in: context)
        case .questCompletion: deleteByIdentity(QuestCompletionCache.self, identity: identity, in: context)
        case .ledgerEntry: deleteByIdentity(LedgerEntryCache.self, identity: identity, in: context)
        case .allowancePeriod: deleteByIdentity(AllowancePeriodCache.self, identity: identity, in: context)
        case .achievement: deleteByIdentity(AchievementCache.self, identity: identity, in: context)
        case .profileAchievement: deleteByIdentity(ProfileAchievementCache.self, identity: identity, in: context)
        case .notificationPreference: deleteByIdentity(NotificationPreferenceCache.self, identity: identity, in: context)
        case .gemLedger: deleteByIdentity(GemLedgerCache.self, identity: identity, in: context)
        case .rewardEvent: deleteByIdentity(RewardEventCache.self, identity: identity, in: context)
        }
        _ = saveContext()
    }

    func invalidate(recordName: String, family: String, type: CachedRecordType) {
        guard let context else { return }
        switch type {
        case .profile:
            deleteByNameAndFamily(ProfileCache.self, recordName: recordName, familyRecordName: family)
        case .family:
            do {
                if let match = try context.fetch(FetchDescriptor<FamilyCache>(predicate: #Predicate { $0.recordName == recordName })).first {
                    context.delete(match)
                }
            } catch {
                logger.warning("Failed to fetch FamilyCache for invalidation: \(error, privacy: .private)")
            }
            _ = saveContext()
        case .quest:
            deleteByNameAndFamily(QuestCache.self, recordName: recordName, familyRecordName: family)
        case .questTemplate:
            deleteByNameAndFamily(QuestTemplateCache.self, recordName: recordName, familyRecordName: family)
        case .questCompletion:
            deleteByNameAndFamily(QuestCompletionCache.self, recordName: recordName, familyRecordName: family)
        case .ledgerEntry:
            deleteByNameAndFamily(LedgerEntryCache.self, recordName: recordName, familyRecordName: family)
        case .allowancePeriod:
            deleteByNameAndFamily(AllowancePeriodCache.self, recordName: recordName, familyRecordName: family)
        case .achievement:
            deleteByNameAndFamily(AchievementCache.self, recordName: recordName, familyRecordName: family)
        case .profileAchievement:
            deleteByNameAndFamily(ProfileAchievementCache.self, recordName: recordName, familyRecordName: family)
        case .notificationPreference:
            deleteByNameAndFamily(NotificationPreferenceCache.self, recordName: recordName, familyRecordName: family)
        case .gemLedger:
            deleteByNameAndFamily(GemLedgerCache.self, recordName: recordName, familyRecordName: family)
        case .rewardEvent:
            deleteByNameAndFamily(RewardEventCache.self, recordName: recordName, familyRecordName: family)
        }
    }

    private func deleteByIdentity(_ type: (some CacheMergeable).Type, identity: ScopedRecordIdentity, in context: ModelContext) {
        let recordName = identity.recordID.recordName
        do {
            guard let match = try context.fetch(type.fetchDescriptor(recordName: recordName)).first else { return }
            if let expectedFamily = identity.familyRecordName, let scoped = match as? any FamilyScopedCache {
                guard scoped.familyRecordName == expectedFamily else {
                    logger
                        .warning(
                            "Cache deletion aborted for \(recordName, privacy: .private): expected family \(expectedFamily, privacy: .private), found \(scoped.familyRecordName, privacy: .private)"
                        )
                    return
                }
            }
            if let scoped = match as? any FamilyScopedCache,
               let sourceZone = scoped.sourceZoneName,
               identity.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName,
               sourceZone != identity.zoneID.zoneName
            {
                let isFamilyMatch: Bool = {
                    guard let expectedFamily = identity.familyRecordName else { return false }
                    return scoped.familyRecordName == expectedFamily
                }()
                let isActiveZone = currentActiveFamilyZoneID.map { $0 == identity.zoneID }
                    ?? false
                if isFamilyMatch, isActiveZone {
                    logger.info(
                        """
                        Deleting orphan cache row for \(recordName, privacy: .private) \
                        after family zone switch: old zone \(sourceZone, privacy: .private) \
                        → active zone \(identity.zoneID.zoneName, privacy: .private)
                        """
                    )
                } else {
                    logger
                        .warning(
                            "Cache deletion aborted for \(recordName, privacy: .private): expected zone \(identity.zoneID.zoneName, privacy: .private), found \(sourceZone, privacy: .private)"
                        )
                    return
                }
            }
            context.delete(match)
        } catch {
            logger.warning("Failed to fetch \(recordName, privacy: .private) for identity deletion: \(error, privacy: .private)")
        }
    }

    func invalidate(_ descriptor: FetchDescriptor<some PersistentModel>) {
        guard let context else { return }
        do {
            if let object = try context.fetch(descriptor).first {
                context.delete(object)
                saveContext()
            }
        } catch {
            logger.warning("Failed to fetch record for invalidation: \(error, privacy: .private)")
        }
    }

    func invalidateByRecordName<T: PersistentModel>(_: T.Type, recordName _: String, predicate: Predicate<T>) {
        invalidate(FetchDescriptor<T>(predicate: predicate))
    }

    func deleteByNameAndFamily<T: CacheMergeable & FamilyScopedCache>(_: T.Type, recordName: String, familyRecordName: String) {
        guard let context else { return }
        let descriptor = FetchDescriptor<T>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyRecordName })
        do {
            let matches = try context.fetch(descriptor)
            for match in matches {
                context.delete(match)
            }
            saveContext()
        } catch {
            logger.warning("Failed to fetch \(T.self, privacy: .public) for invalidation: \(error, privacy: .private)")
        }
    }

    // MARK: - Deprecated shims — keep for ProjectTests that still call per-type wrappers.

    @available(*, deprecated, message: "Use invalidate(identity:type:)")
    func invalidateRecord(identity: ScopedRecordIdentity, type: CachedRecordType) {
        invalidate(identity: identity, type: type)
    }

    @available(*, deprecated, message: "Use invalidate(recordName:family:type:)")
    func invalidateQuest(recordName: String, family: String) {
        invalidate(recordName: recordName, family: family, type: .quest)
    }

    @available(*, deprecated, message: "Use invalidate(identity:type:)")
    func invalidateQuest(identity: ScopedRecordIdentity) {
        invalidate(identity: identity, type: .quest)
    }

    @available(*, deprecated, message: "Use invalidate(recordName:family:type:)")
    func invalidateLedgerEntry(recordName: String, family: String) {
        invalidate(recordName: recordName, family: family, type: .ledgerEntry)
    }

    @available(*, deprecated, message: "Use invalidate(identity:type:)")
    func invalidateLedgerEntry(identity: ScopedRecordIdentity) {
        invalidate(identity: identity, type: .ledgerEntry)
    }

    // MARK: - Per-Family Purge

    func purgeFamily(recordName: String) {
        let familyDescriptor = FetchDescriptor<FamilyCache>(predicate: #Predicate { $0.recordName == recordName })
        guard let context else { return }
        do {
            if let family = try context.fetch(familyDescriptor).first {
                context.delete(family)
            }
        } catch {
            logger.error("Failed to fetch family for purge: \(error, privacy: .private)")
            return
        }
        deleteAll(from: context, where: #Predicate<QuestCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<QuestTemplateCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<QuestCompletionCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<LedgerEntryCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<AllowancePeriodCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<AchievementCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<ProfileAchievementCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<ProfileCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<NotificationPreferenceCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<GemLedgerCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<RewardEventCache> { $0.familyRecordName == recordName })
        invalidateFreshness(forFamilyRecordName: recordName)
        saveContext()
    }

    // MARK: - Bulk Clear

    func clearAll() throws {
        guard let context else { return }
        try context.delete(model: QuestCache.self)
        try context.delete(model: QuestTemplateCache.self)
        try context.delete(model: ProfileCache.self)
        try context.delete(model: QuestCompletionCache.self)
        try context.delete(model: FamilyCache.self)
        try context.delete(model: LedgerEntryCache.self)
        try context.delete(model: AllowancePeriodCache.self)
        try context.delete(model: AchievementCache.self)
        try context.delete(model: ProfileAchievementCache.self)
        try context.delete(model: NotificationPreferenceCache.self)
        try context.delete(model: GemLedgerCache.self)
        try context.delete(model: RewardEventCache.self)
        do { try trySaveContext() } catch {
            logger.error("Failed to save after clearing cache: \(error, privacy: .private)")
            throw error
        }
        invalidateAllFreshness()
    }
}
