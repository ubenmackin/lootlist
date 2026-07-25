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

/// Centralized sync coordinator that populates and updates the local SwiftData
/// cache (`CacheService`) from CloudKit on cold launch and in response to push notifications.
@MainActor
@Observable
final class SyncEngine {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "SyncEngine"
    )

    private let cloudKit: CloudKitService
    private let cacheService: CacheService
    private let syncCoordinator: AppSyncCoordinator

    private(set) var isSyncing: Bool = false
    private var needsResync: Bool = false
    private(set) var lastSyncedAt: Date?
    var syncError: String?

    private var syncTask: Task<Void, Never>?

    init(cloudKit: CloudKitService,
         cacheService: CacheService,
         syncCoordinator: AppSyncCoordinator)
    {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.syncCoordinator = syncCoordinator

        listenToPushNotifications()
    }

    /// Primary launch sync entry point. Queries CloudKit for all family entity types
    /// in parallel and populates SwiftData so all views can render instantly from local cache.
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
            if let family = try await familyTask.first {
                cacheService.upsertFamily(family)
            }
        } catch {
            logger.error("Failed to sync family: \(error)")
        }

        do {
            let notifPrefs = try await notifPrefsTask
            cacheService.upsertNotificationPreferences(notifPrefs)
        } catch {
            logger.error("Failed to sync notification preferences: \(error)")
        }

        do {
            let profiles = try await profilesTask
            cacheService.upsertProfiles(profiles, family: familyRecordName)
        } catch {
            logger.error("Failed to sync profiles: \(error)")
        }

        do {
            let quests = try await questsTask
            cacheService.upsertQuests(quests, family: familyRecordName)
        } catch {
            logger.error("Failed to sync quests: \(error)")
        }

        do {
            let templates = try await templatesTask
            cacheService.upsertQuestTemplates(templates, family: familyRecordName)
        } catch {
            logger.error("Failed to sync quest templates: \(error)")
        }

        do {
            let completions = try await completionsTask
            cacheService.upsertQuestCompletions(completions, family: familyRecordName)
        } catch {
            logger.error("Failed to sync quest completions: \(error)")
        }

        do {
            let ledgerEntries = try await ledgerTask
            cacheService.upsertLedgerEntries(ledgerEntries)
        } catch {
            logger.error("Failed to sync ledger entries: \(error)")
        }

        do {
            let allowancePeriods = try await allowanceTask
            cacheService.upsertAllowancePeriods(allowancePeriods)
        } catch {
            logger.error("Failed to sync allowance periods: \(error)")
        }

        do {
            let achievements = try await achievementsTask
            cacheService.upsertAchievements(achievements)
        } catch {
            logger.error("Failed to sync achievements: \(error)")
        }

        do {
            let profileAchievements = try await profileAchievementsTask
            cacheService.upsertProfileAchievements(profileAchievements)
        } catch {
            logger.error("Failed to sync profile achievements: \(error)")
        }

        logger.info("syncAll completed successfully.")
    }

    private func listenToPushNotifications() {
        let (stream, _) = syncCoordinator.subscribe()
        syncTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .recordChanged, .zoneReset, .shareAccepted:
                    await syncAll()
                }
            }
        }
    }
}
