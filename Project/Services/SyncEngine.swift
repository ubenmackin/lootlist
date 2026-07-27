//
//  SyncEngine.swift
//  LootList
//
//  Created for Local-First SwiftData Architecture & Sync Engine.
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

    func syncAll(familyRecordName: String? = nil) async {
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
            NotificationCenter.default.post(name: .syncDidComplete, object: nil)

            if needsResync {
                Task {
                    await syncAll(familyRecordName: familyRecordName)
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
        } catch {
            logger.error("Failed to sync family: \(error)")
        }

        do {
            let notifPrefs = try await notifPrefsTask
            await backgroundCache.batchUpsertNotificationPreferences(notifPrefs)
        } catch {
            logger.error("Failed to sync notification preferences: \(error)")
        }

        do {
            let profiles = try await profilesTask
            await backgroundCache.batchUpsertProfiles(profiles)
            await backgroundCache.purgeMissingProfiles(validRecordNames: Set(profiles.map(\.id.recordName)))
        } catch {
            logger.error("Failed to sync profiles: \(error)")
        }

        do {
            let quests = try await questsTask
            await backgroundCache.batchUpsertQuests(quests)
            await backgroundCache.purgeMissingQuests(validRecordNames: Set(quests.map(\.id.recordName)))
        } catch {
            logger.error("Failed to sync quests: \(error)")
        }

        do {
            let templates = try await templatesTask
            await backgroundCache.batchUpsertQuestTemplates(templates)
            await backgroundCache.purgeMissingQuestTemplates(validRecordNames: Set(templates.map(\.id.recordName)))
        } catch {
            logger.error("Failed to sync quest templates: \(error)")
        }

        do {
            let completions = try await completionsTask
            await backgroundCache.batchUpsertQuestCompletions(completions)
            await backgroundCache.purgeMissingQuestCompletions(validRecordNames: Set(completions.map(\.id.recordName)))
        } catch {
            logger.error("Failed to sync quest completions: \(error)")
        }

        do {
            let ledgerEntries = try await ledgerTask
            await backgroundCache.batchUpsertLedgerEntries(ledgerEntries)
            await backgroundCache.purgeMissingLedgerEntries(validRecordNames: Set(ledgerEntries.map(\.id.recordName)))
        } catch {
            logger.error("Failed to sync ledger entries: \(error)")
        }

        do {
            let allowancePeriods = try await allowanceTask
            await backgroundCache.batchUpsertAllowancePeriods(allowancePeriods)
            await backgroundCache.purgeMissingAllowancePeriods(validRecordNames: Set(allowancePeriods.map(\.id.recordName)))
        } catch {
            logger.error("Failed to sync allowance periods: \(error)")
        }

        do {
            let achievements = try await achievementsTask
            await backgroundCache.batchUpsertAchievements(achievements)
            await backgroundCache.purgeMissingAchievements(validRecordNames: Set(achievements.map(\.id.recordName)))
        } catch {
            logger.error("Failed to sync achievements: \(error)")
        }

        do {
            let profileAchievements = try await profileAchievementsTask
            await backgroundCache.batchUpsertProfileAchievements(profileAchievements)
            await backgroundCache.purgeMissingProfileAchievements(validRecordNames: Set(profileAchievements.map(\.id.recordName)))
        } catch {
            logger.error("Failed to sync profile achievements: \(error)")
        }

        logger.info("syncAll completed successfully.")
    }

    func incrementalSync() async {
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
            NotificationCenter.default.post(name: .syncDidComplete, object: nil)

            if needsResync {
                Task {
                    await incrementalSync()
                }
            }
        }

        let tokenKey = "ck_server_change_token"
        var cachedToken: CKServerChangeToken?
        if let data = UserDefaults.standard.data(forKey: tokenKey) {
            cachedToken = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }

        guard let token = cachedToken else {
            logger.info("No server change token found, executing syncAll()")
            await syncAll()
            return
        }

        logger.info("Starting incrementalSync with change token")
        do {
            let result = try await cloudKit.fetchZoneChanges(since: token)

            for record in result.changedRecords {
                await processChangedRecord(record)
            }

            for (deletedID, recordType) in result.deletedRecordIDs {
                // Resolve the raw CloudKit `CKRecordType` string to a typed
                // `CachedRecordType` before delegating to the cache actor. This
                // hardens the delete path against Swift class-name /
                // CKRecordType divergence — e.g. `QuestCompletion`
                // (`recordType == "QuestLog"`) whose previous string-literal
                // switch in `BackgroundCacheActor` never matched, silently
                // leaking stale `QuestCompletionCache` rows.
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
                Task {
                    await incrementalSync()
                }
            }

            logger.info("incrementalSync completed successfully.")
        } catch {
            logger.error("incrementalSync failed: \(error, privacy: .private), falling back to syncAll()")
            UserDefaults.standard.removeObject(forKey: tokenKey)
            await syncAll()
        }
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
                await backgroundCache.batchUpsertProfiles([profile])
            }
            return true
        case Quest.recordType:
            if let quest = try? Quest(record: record) {
                await backgroundCache.batchUpsertQuests([quest])
            }
            return true
        case QuestTemplate.recordType:
            if let template = try? QuestTemplate(record: record) {
                await backgroundCache.batchUpsertQuestTemplates([template])
            }
            return true
        case QuestCompletion.recordType:
            if let completion = try? QuestCompletion(record: record) {
                await backgroundCache.batchUpsertQuestCompletions([completion])
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
                await backgroundCache.batchUpsertLedgerEntries([entry])
            }
        case AllowancePeriod.recordType:
            if let period = try? AllowancePeriod(record: record) {
                await backgroundCache.batchUpsertAllowancePeriods([period])
            }
        case Achievement.recordType:
            if let achievement = try? Achievement(record: record) {
                await backgroundCache.batchUpsertAchievements([achievement])
            }
        case ProfileAchievement.recordType:
            if let pa = try? ProfileAchievement(record: record) {
                await backgroundCache.batchUpsertProfileAchievements([pa])
            }
        case NotificationPreference.recordType:
            if let pref = try? NotificationPreference(record: record) {
                await backgroundCache.batchUpsertNotificationPreferences([pref])
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
                    await incrementalSync()
                case .zoneReset, .shareAccepted:
                    UserDefaults.standard.removeObject(forKey: "ck_server_change_token")
                    await syncAll()
                }
            }
        }
    }
}
