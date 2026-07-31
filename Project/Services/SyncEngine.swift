//
//  SyncEngine.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import Observation
import os

@MainActor
@Observable
final class SyncEngine {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "SyncEngine"
    )

    private let cloudKit: CloudKitService
    private let cacheService: CacheService
    private let backgroundCache: BackgroundCacheActor
    private let syncCoordinator: AppSyncCoordinator

    private(set) var isSyncing: Bool = false
    private var needsResync: Bool = false
    private(set) var lastSyncedAt: Date?
    var syncError: String?

    private var syncTask: Task<Void, Never>?

    init(cloudKit: CloudKitService,
         cacheService: CacheService,
         backgroundCache: BackgroundCacheActor,
         syncCoordinator: AppSyncCoordinator)
    {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.backgroundCache = backgroundCache
        self.syncCoordinator = syncCoordinator

        listenToPushNotifications()
    }

    /// Full sync scoped to a single family zone.
    func syncAll(familyRecordName: String) async {
        await _syncAll(familyRecordName: familyRecordName)
    }

    /// Bootstrap-only full sync used when no family context is available.
    func syncAllFamiliesUnscoped() async {
        await _syncAll(familyRecordName: nil)
    }

    /// Shared implementation for scoped and unscoped full syncs.
    private func _syncAll(familyRecordName: String?) async {
        if isSyncing {
            needsResync = true
            return
        }

        isSyncing = true
        needsResync = false
        syncError = nil
        var syncErrors: [String] = []

        defer {
            isSyncing = false
            lastSyncedAt = Date()
            let userInfo: [String: Any]? = syncErrors.isEmpty ? nil : ["errors": syncErrors]
            NotificationCenter.default.post(name: .syncDidComplete, object: self, userInfo: userInfo)

            if needsResync {
                Task {
                    if let familyRecordName {
                        await syncAll(familyRecordName: familyRecordName)
                    } else {
                        await syncAllFamiliesUnscoped()
                    }
                }
            }
        }

        logger.info("Starting syncAll for familyRecordName=\(familyRecordName ?? "all", privacy: .private)")

        let zoneID = cloudKit.resolvedZoneID
        let db = cloudKit.activeFamilyDatabase

        async let familyTask = cloudKit.query(Family.self, predicate: NSPredicate(value: true), in: zoneID, using: db)
        async let notifPrefsTask = cloudKit.query(NotificationPreference.self, predicate: NSPredicate(value: true), in: zoneID, using: db)
        async let profilesTask = cloudKit.query(Profile.self, predicate: NSPredicate(value: true), in: zoneID, using: db)
        async let questsTask = cloudKit.query(Quest.self, predicate: NSPredicate(value: true), in: zoneID, using: db)
        async let templatesTask = cloudKit.query(QuestTemplate.self, predicate: NSPredicate(value: true), in: zoneID, using: db)
        async let completionsTask = cloudKit.query(QuestCompletion.self, predicate: NSPredicate(value: true), in: zoneID, using: db)
        async let ledgerTask = cloudKit.query(LedgerEntry.self, predicate: NSPredicate(value: true), in: zoneID, using: db)
        async let allowanceTask = cloudKit.query(AllowancePeriod.self, predicate: NSPredicate(value: true), in: zoneID, using: db)
        async let achievementsTask = cloudKit.query(Achievement.self, predicate: NSPredicate(value: true), in: zoneID, using: db)
        async let profileAchievementsTask = cloudKit.query(ProfileAchievement.self, predicate: NSPredicate(value: true), in: zoneID, using: db)

        do {
            let families = try await familyTask
            await backgroundCache.batchUpsertFamilies(families)
            await backgroundCache.purgeMissingFamilies(validRecordNames: Set(families.map(\.id.recordName)))
        } catch {
            logger.error("Failed to sync family: \(error)")
            syncErrors.append("Family: \(error.localizedDescription)")
        }

        do {
            let notifPrefs = try await notifPrefsTask
            await backgroundCache.batchUpsertNotificationPreferences(notifPrefs, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingNotificationPreferences(validRecordNames: Set(notifPrefs.map(\.id.recordName)), familyRecordName: familyRecordName)
        } catch {
            logger.error("Failed to sync notification preferences: \(error)")
            syncErrors.append("NotificationPreferences: \(error.localizedDescription)")
        }

        do {
            let profiles = try await profilesTask
            await backgroundCache.batchUpsertProfiles(profiles, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingProfiles(validRecordNames: Set(profiles.map(\.id.recordName)), familyRecordName: familyRecordName)
        } catch {
            logger.error("Failed to sync profiles: \(error)")
            syncErrors.append("Profiles: \(error.localizedDescription)")
        }

        do {
            let quests = try await questsTask
            await backgroundCache.batchUpsertQuests(quests, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingQuests(validRecordNames: Set(quests.map(\.id.recordName)), familyRecordName: familyRecordName)
        } catch {
            logger.error("Failed to sync quests: \(error)")
            syncErrors.append("Quests: \(error.localizedDescription)")
        }

        do {
            let templates = try await templatesTask
            await backgroundCache.batchUpsertQuestTemplates(templates, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingQuestTemplates(validRecordNames: Set(templates.map(\.id.recordName)), familyRecordName: familyRecordName)
        } catch {
            logger.error("Failed to sync quest templates: \(error)")
            syncErrors.append("QuestTemplates: \(error.localizedDescription)")
        }

        do {
            let completions = try await completionsTask
            await backgroundCache.batchUpsertQuestCompletions(completions, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingQuestCompletions(validRecordNames: Set(completions.map(\.id.recordName)), familyRecordName: familyRecordName)
        } catch {
            logger.error("Failed to sync quest completions: \(error)")
            syncErrors.append("QuestCompletions: \(error.localizedDescription)")
        }

        do {
            let ledgerEntries = try await ledgerTask
            await backgroundCache.batchUpsertLedgerEntries(ledgerEntries, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingLedgerEntries(validRecordNames: Set(ledgerEntries.map(\.id.recordName)), familyRecordName: familyRecordName)
        } catch {
            logger.error("Failed to sync ledger entries: \(error)")
            syncErrors.append("LedgerEntries: \(error.localizedDescription)")
        }

        do {
            let allowancePeriods = try await allowanceTask
            await backgroundCache.batchUpsertAllowancePeriods(allowancePeriods, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingAllowancePeriods(validRecordNames: Set(allowancePeriods.map(\.id.recordName)), familyRecordName: familyRecordName)
        } catch {
            logger.error("Failed to sync allowance periods: \(error)")
            syncErrors.append("AllowancePeriods: \(error.localizedDescription)")
        }

        do {
            let achievements = try await achievementsTask
            await backgroundCache.batchUpsertAchievements(achievements, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingAchievements(validRecordNames: Set(achievements.map(\.id.recordName)), familyRecordName: familyRecordName)
        } catch {
            logger.error("Failed to sync achievements: \(error)")
            syncErrors.append("Achievements: \(error.localizedDescription)")
        }

        do {
            let profileAchievements = try await profileAchievementsTask
            await backgroundCache.batchUpsertProfileAchievements(profileAchievements, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingProfileAchievements(validRecordNames: Set(profileAchievements.map(\.id.recordName)), familyRecordName: familyRecordName)
        } catch {
            logger.error("Failed to sync profile achievements: \(error)")
            syncErrors.append("ProfileAchievements: \(error.localizedDescription)")
        }

        logger.info("syncAll completed successfully.")
    }

    /// Incremental delta sync using CKServerChangeToken for a specific family.
    func incrementalSync(familyRecordName: String? = nil) async {
        if isSyncing {
            needsResync = true
            return
        }

        isSyncing = true
        needsResync = false
        syncError = nil

        defer {
            isSyncing = false
            lastSyncedAt = Date()
            NotificationCenter.default.post(name: .syncDidComplete, object: self)

            if needsResync {
                Task {
                    await incrementalSync(familyRecordName: familyRecordName)
                }
            }
        }

        let zoneID = cloudKit.resolvedZoneID
        let db = cloudKit.activeFamilyDatabase
        let tokenKey = tokenKey(for: zoneID, db: db)

        var cachedToken: CKServerChangeToken?
        if let data = UserDefaults.standard.data(forKey: tokenKey) {
            cachedToken = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }

        guard let token = cachedToken else {
            logger.info("No server change token found, executing syncAll(familyRecordName: \(familyRecordName ?? "all", privacy: .private))")
            isSyncing = false
            if let familyRecordName {
                await syncAll(familyRecordName: familyRecordName)
            } else {
                await syncAllFamiliesUnscoped()
            }
            return
        }

        logger.info("Starting incrementalSync with change token")
        do {
            let result = try await cloudKit.fetchZoneChanges(since: token)

            for record in result.changedRecords {
                await processChangedRecord(record)
            }

            for (deletedID, recordType) in result.deletedRecordIDs {
                guard let cachedType = CachedRecordType.recordType(for: recordType) else {
                    logger.warning("Skipping delete of unknown recordType '\(recordType, privacy: .public)' for record \(deletedID.recordName, privacy: .private)")
                    continue
                }
                await backgroundCache.deleteRecord(recordName: deletedID.recordName, type: cachedType)
            }

            if let newToken = result.newToken {
                if let data = try? NSKeyedArchiver.archivedData(withRootObject: newToken, requiringSecureCoding: true) {
                    UserDefaults.standard.set(data, forKey: tokenKey)
                }
            }

            if result.moreComing {
                needsResync = true
            }

            logger.info("incrementalSync completed successfully.")
        } catch {
            logger.error("incrementalSync failed: \(error, privacy: .private), falling back to syncAll(familyRecordName: \(familyRecordName ?? "all", privacy: .private))")
            UserDefaults.standard.removeObject(forKey: tokenKey)
            isSyncing = false
            if let familyRecordName {
                await syncAll(familyRecordName: familyRecordName)
            } else {
                await syncAllFamiliesUnscoped()
            }
        }
    }

    /// Returns a UserDefaults key scoped to a specific record zone and database scope.
    func tokenKey(for zoneID: CKRecordZone.ID, db: CKDatabase?) -> String {
        let dbLabel: CKDatabase.Scope = db?.databaseScope ?? .private
        let scopeLabel = dbLabel == .shared ? "shared" : "private"
        return "ck_change_token.\(zoneID.zoneName).\(scopeLabel)"
    }

    private func processChangedRecord(_ record: CKRecord) async {
        if await processCoreRecord(record) {
            return
        }
        await processSecondaryRecord(record)
    }

    private func processCoreRecord(_ record: CKRecord) async -> Bool {
        switch record.recordType {
        case Family.recordType:
            if let family = try? Family(record: record) {
                await backgroundCache.batchUpsertFamilies([family])
            }
            return true
        case Profile.recordType:
            if let profile = try? Profile(record: record) {
                await backgroundCache.batchUpsertProfiles([profile], familyRecordName: profile.family.recordID.recordName)
            }
            return true
        case Quest.recordType:
            if let quest = try? Quest(record: record) {
                await backgroundCache.batchUpsertQuests([quest], familyRecordName: quest.family.recordID.recordName)
            }
            return true
        case QuestTemplate.recordType:
            if let template = try? QuestTemplate(record: record) {
                await backgroundCache.batchUpsertQuestTemplates([template], familyRecordName: template.family.recordID.recordName)
            }
            return true
        case QuestCompletion.recordType:
            if let completion = try? QuestCompletion(record: record) {
                await backgroundCache.batchUpsertQuestCompletions([completion], familyRecordName: completion.family.recordID.recordName)
            }
            return true
        default:
            return false
        }
    }

    private func processSecondaryRecord(_ record: CKRecord) async {
        switch record.recordType {
        case LedgerEntry.recordType:
            if let entry = try? LedgerEntry(record: record) {
                await backgroundCache.batchUpsertLedgerEntries([entry], familyRecordName: entry.family.recordID.recordName)
            }
        case AllowancePeriod.recordType:
            if let period = try? AllowancePeriod(record: record) {
                await backgroundCache.batchUpsertAllowancePeriods([period], familyRecordName: period.family.recordID.recordName)
            }
        case Achievement.recordType:
            if let achievement = try? Achievement(record: record) {
                await backgroundCache.batchUpsertAchievements([achievement], familyRecordName: achievement.family.recordID.recordName)
            }
        case ProfileAchievement.recordType:
            if let pa = try? ProfileAchievement(record: record) {
                await backgroundCache.batchUpsertProfileAchievements([pa], familyRecordName: pa.family.recordID.recordName)
            }
        case NotificationPreference.recordType:
            if let pref = try? NotificationPreference(record: record) {
                await backgroundCache.batchUpsertNotificationPreferences([pref], familyRecordName: pref.family.recordID.recordName)
            }
        default:
            break
        }
    }

    private func listenToPushNotifications() {
        let (stream, _) = syncCoordinator.subscribe()
        syncTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .recordChanged:
                    let familyRecordName: String? = cloudKit.activeFamilyZoneID?.zoneName
                    await incrementalSync(familyRecordName: familyRecordName)
                case let .shareAccepted(shareID):
                    let acceptedZoneID = shareID.zoneID
                    UserDefaults.standard.removeObject(forKey: tokenKey(for: acceptedZoneID, db: cloudKit.sharedDatabase))
                    cacheService.clearAll()
                    cloudKit.activeFamilyZoneID = acceptedZoneID
                    cloudKit.activeIsOwner = false
                    await syncAll(familyRecordName: acceptedZoneID.zoneName)
                case .zoneReset:
                    UserDefaults.standard.removeObject(forKey: tokenKey(for: cloudKit.resolvedZoneID, db: cloudKit.activeFamilyDatabase))
                    cacheService.clearAll()
                    if let familyRecordName = cloudKit.activeFamilyZoneID?.zoneName {
                        await syncAll(familyRecordName: familyRecordName)
                    } else {
                        await syncAllFamiliesUnscoped()
                    }
                }
            }
        }
    }
}
