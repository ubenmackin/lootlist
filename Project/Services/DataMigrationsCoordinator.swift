//
//  DataMigrationsCoordinator.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os

@MainActor
final class DataMigrationsCoordinator {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "DataMigrations")
    private let defaults: UserDefaults

    enum MigrationError: LocalizedError {
        case incompleteBackfill(String)
        case missingActiveZone

        var errorDescription: String? {
            switch self {
            case let .incompleteBackfill(reason):
                "Migration incomplete: \(reason)"
            case .missingActiveZone:
                "Active family zone missing for migration"
            }
        }
    }

    struct MigrationStep {
        let id: String
        let version: Int
        let run: () async throws -> Void
    }

    private var steps: [MigrationStep] = []
    private var inFlightFamilyKeys: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func register(_ step: MigrationStep) {
        steps.append(step)
    }

    func runPendingMigrations(accountID: String, familyRecordName: String) async {
        guard !accountID.isEmpty, !familyRecordName.isEmpty else {
            logger.warning("runPendingMigrations skipped: accountID and familyRecordName are required")
            return
        }
        let lockKey = "\(accountID).\(familyRecordName)"
        guard !inFlightFamilyKeys.contains(lockKey) else {
            logger.info("Migrations already in flight for \(lockKey, privacy: .private), skipping.")
            return
        }
        inFlightFamilyKeys.insert(lockKey)
        defer { inFlightFamilyKeys.remove(lockKey) }

        for step in steps {
            let key = "migration.\(accountID).\(familyRecordName).\(step.id).v\(step.version).complete"
            guard !defaults.bool(forKey: key) else {
                logger.debug("Migration \(step.id, privacy: .public) v\(step.version) already complete for \(lockKey, privacy: .private), skipping")
                continue
            }

            logger.info("Running migration: \(step.id, privacy: .public) v\(step.version) for \(lockKey, privacy: .private)")
            do {
                try await step.run()
                defaults.set(true, forKey: key)
                logger.info("Migration \(step.id) v\(step.version) completed successfully")
            } catch {
                logger.error("Migration \(step.id) v\(step.version) failed: \(error, privacy: .private)")
            }
        }
    }

    private static func fetchRecordOrNil<T: CloudKitRecord>(
        _ type: T.Type,
        id: CKRecord.ID,
        cloudKit: any CloudKitServiceProtocol
    ) async throws -> T? {
        do {
            return try await cloudKit.fetch(type, id: id, using: nil)
        } catch let error as CloudKitServiceError {
            switch error {
            case .notFound:
                return nil
            default:
                throw error
            }
        } catch let ckError as CKError where ckError.code == .unknownItem {
            return nil
        } catch {
            throw error
        }
    }
}

// MARK: - Migration Steps

extension DataMigrationsCoordinator {
    static func questNameBackfillV1(cloudKit: any CloudKitServiceProtocol) -> MigrationStep {
        MigrationStep(id: "QuestNameBackfillV1", version: 1) {
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "DataMigrations")
            guard let activeZone = cloudKit.activeFamilyZoneID else {
                logger.info("No active family zone, skipping quest name backfill.")
                return
            }
            let allQuests = try await cloudKit.query(Quest.self, predicate: NSPredicate(value: true), in: activeZone)
            let needsBackfill = allQuests.filter { $0.name == nil }
            guard !needsBackfill.isEmpty else {
                logger.info("No quests need name backfill.")
                return
            }
            var hadFailures = false
            for quest in needsBackfill {
                do {
                    var updated = quest
                    if let template = try await fetchRecordOrNil(
                        QuestTemplate.self,
                        id: quest.template.recordID,
                        cloudKit: cloudKit
                    ) {
                        updated.name = template.name
                    } else {
                        logger.warning("Template missing for quest \(quest.id.recordName, privacy: .private); reconciling with fallback title.")
                        updated.name = "Quest"
                    }
                    _ = try await cloudKit.save(updated)
                } catch {
                    logger.error("Failed to backfill quest \(quest.id.recordName, privacy: .private): \(error, privacy: .private)")
                    hadFailures = true
                }
            }
            if hadFailures {
                throw MigrationError.incompleteBackfill("Quest name backfill had save errors; migration marked incomplete for retry")
            }
        }
    }

    static func questTargetCountBackfillV2(backgroundCache: BackgroundCacheActor) -> MigrationStep {
        MigrationStep(id: "QuestTargetCountBackfillV2", version: 2) {
            await backgroundCache.backfillTargetCountGlobally()
        }
    }

    static func questLedgerBackfillV1(cloudKit: any CloudKitServiceProtocol, cacheService: CacheService?) -> MigrationStep {
        MigrationStep(id: "QuestLedgerBackfillV1", version: 1) {
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "DataMigrations")
            guard let zoneID = cloudKit.activeFamilyZoneID else {
                logger.info("No active family zone, skipping ledger backfill.")
                return
            }
            let periods = try await cloudKit.query(
                AllowancePeriod.self,
                predicate: NSPredicate(value: true),
                in: zoneID
            )
            let existingLedgers = try await cloudKit.query(
                LedgerEntry.self,
                predicate: NSPredicate(value: true),
                in: zoneID
            )
            for period in periods {
                var paidAmount = period.paidAmount ?? period.totalEarned
                guard paidAmount > 0 else { continue }
                let entryRecordName: String
                let descriptionPrefix: String
                if period.status == .paid {
                    entryRecordName = "payout-\(period.id.recordName)"
                    descriptionPrefix = "Quest earnings"
                    let rtID = CKRecord.ID(recordName: "rt-\(period.id.recordName)", zoneID: zoneID)
                    let realTimeEntry = try await fetchRecordOrNil(
                        LedgerEntry.self,
                        id: rtID,
                        cloudKit: cloudKit
                    )
                    if realTimeEntry != nil {
                        continue
                    }
                    let weekEnd = Calendar.iso8601UTC.date(byAdding: .day, value: 7, to: period.weekOf) ?? period.weekOf.addingTimeInterval(7 * 86400)
                    let depositBonusSum = existingLedgers
                        .filter {
                            $0.profile.recordID == period.profile.recordID &&
                                $0.source != "quest" &&
                                $0.amount > 0 &&
                                $0.date >= period.weekOf &&
                                $0.date < weekEnd
                        }
                        .reduce(0.0) { $0 + $1.amount }
                    paidAmount = max(0, paidAmount - depositBonusSum)
                    guard paidAmount > 0 else { continue }
                } else {
                    entryRecordName = "rt-\(period.id.recordName)"
                    descriptionPrefix = "Quest earnings — real-time"
                }
                let targetID = CKRecord.ID(recordName: entryRecordName, zoneID: zoneID)
                let existing = try await fetchRecordOrNil(
                    LedgerEntry.self,
                    id: targetID,
                    cloudKit: cloudKit
                )
                if existing != nil {
                    continue
                }
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                let entry = LedgerEntry(
                    profile: period.profile,
                    amount: abs(paidAmount),
                    description: "\(descriptionPrefix) (week of \(formatter.string(from: period.weekOf)))",
                    date: period.paidDate ?? period.weekOf,
                    source: "quest",
                    family: period.family,
                    id: targetID
                )
                let saved = try await cloudKit.save(entry, in: zoneID, using: nil)
                await cacheService?.upsertLedgerEntry(saved)
            }
        }
    }

    static func achievementMigrationV1(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService?
    ) -> MigrationStep {
        MigrationStep(id: "AchievementMigrationV1", version: 1) {
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "DataMigrations")
            guard let zoneID = cloudKit.activeFamilyZoneID else {
                logger.info("No active family zone, skipping achievement migration.")
                return
            }
            let allAchievements = try await cloudKit.query(
                Achievement.self,
                predicate: NSPredicate(value: true),
                in: zoneID
            )
            for achievement in allAchievements {
                let familyName = achievement.family.recordID.recordName
                let expectedPrefix = "\(familyName)-"
                if !achievement.id.recordName.hasPrefix(expectedPrefix) {
                    let req = achievement.requirementType
                    let canonicalID = CKRecord.ID(recordName: "\(familyName)-\(req.rawValue)", zoneID: zoneID)
                    let canonical = Achievement(
                        id: canonicalID,
                        name: achievement.name,
                        description: achievement.description,
                        iconSystemName: achievement.iconSystemName,
                        category: achievement.category,
                        requirementType: achievement.requirementType,
                        requirementValue: achievement.requirementValue,
                        family: achievement.family
                    )
                    let saved = try await cloudKit.save(canonical, in: zoneID, using: nil)
                    await cacheService?.upsertAchievement(saved)
                    do {
                        try await cloudKit.delete(achievement.id, in: zoneID, using: nil)
                    } catch {
                        logger.warning("Failed to delete legacy achievement \(achievement.id.recordName, privacy: .private): \(error, privacy: .private)")
                        throw error
                    }
                    logger.info("Migrated legacy achievement \(achievement.id.recordName, privacy: .private) to canonical \(canonicalID.recordName, privacy: .private)")
                }
            }
        }
    }

    static func heroNotificationPreferenceBackfillV1(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService?,
        syncCoordinator: CKSyncEngineCoordinator? = nil
    ) -> MigrationStep {
        MigrationStep(id: "heroNotificationPreferenceBackfillV1", version: 1) {
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "DataMigrations")
            guard let zoneID = cloudKit.activeFamilyZoneID else {
                logger.info("No active family zone, skipping notification preference backfill.")
                return
            }
            let familyRecordName = zoneID.zoneName
            let isOwner = cloudKit.activeIsOwner
            let profiles = try await cloudKit.query(Profile.self, predicate: NSPredicate(value: true), in: zoneID)
            let activeProfiles = profiles.filter(\.isActive)
            guard !activeProfiles.isEmpty else {
                logger.info("No active profiles for notification preference backfill.")
                return
            }
            let existingPrefs = try await cloudKit.query(NotificationPreference.self, predicate: NSPredicate(value: true), in: zoneID)
            let existingNames = Set(existingPrefs.map(\.id.recordName))
            var toCreate: [NotificationPreference] = []
            for profile in activeProfiles {
                let profileName = profile.id.recordName
                let familyRef = profile.family
                for event in NotificationEventType.allCases {
                    let deterministicName = "\(familyRecordName)-\(profileName)-\(event.rawValue)"
                    let altName = "pref-\(profileName)-\(familyRecordName)-\(event.rawValue)"
                    if existingNames.contains(deterministicName) || existingNames.contains(altName) {
                        continue
                    }
                    if let cacheService,
                       cacheService.fetchNotificationPreference(
                           profileRecordName: profileName,
                           familyRecordName: familyRecordName,
                           eventType: event.rawValue
                       ) != nil
                    {
                        continue
                    }
                    let recordID = CKRecord.ID(recordName: deterministicName, zoneID: zoneID)
                    let pref = NotificationPreference(
                        profile: CKRecord.Reference(recordID: profile.id, action: .none),
                        eventType: event,
                        enabled: true,
                        family: familyRef,
                        id: recordID
                    )
                    toCreate.append(pref)
                }
            }
            guard !toCreate.isEmpty else {
                logger.info("No missing notification preferences to backfill.")
                return
            }
            if let cacheService {
                await cacheService.upsertNotificationPreferences(toCreate, family: familyRecordName)
            }
            for pref in toCreate {
                do {
                    let saved = try await cloudKit.save(pref, in: zoneID, using: nil)
                    await cacheService?.upsertNotificationPreference(saved)
                    syncCoordinator?.enqueueSave(recordID: saved.id, isOwner: isOwner)
                } catch {
                    logger.warning("Failed to backfill notification preference \(pref.id.recordName, privacy: .private): \(error, privacy: .private)")
                }
            }
            logger.info("Notification preference backfill created \(toCreate.count) rows.")
        }
    }

    static func allowancePeriodSeedV1(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService?,
        syncCoordinator: CKSyncEngineCoordinator? = nil
    ) -> MigrationStep {
        MigrationStep(id: "allowancePeriodSeedV1", version: 1) {
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "DataMigrations")
            guard let zoneID = cloudKit.activeFamilyZoneID else {
                logger.info("No active family zone, skipping allowance period seed.")
                return
            }
            let familyRecordName = zoneID.zoneName
            let isOwner = cloudKit.activeIsOwner
            let family: Family? = if let cached = cacheService?.fetchFamily(recordName: familyRecordName) {
                cached.toFamily(zoneID: zoneID)
            } else {
                try await fetchRecordOrNil(Family.self, id: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), cloudKit: cloudKit)
            }
            let profiles = try await cloudKit.query(Profile.self, predicate: NSPredicate(value: true), in: zoneID)
            let activeProfiles = profiles.filter(\.isActive)
            guard !activeProfiles.isEmpty else {
                logger.info("No active profiles for allowance period seed.")
                return
            }
            let existingPeriods = try await cloudKit.query(AllowancePeriod.self, predicate: NSPredicate(value: true), in: zoneID)
            let existingNames = Set(existingPeriods.map(\.id.recordName))
            var created = 0
            for profile in activeProfiles {
                let payoutDay = profile.payoutDay ?? family?.payoutDay ?? .sunday
                let startOfWeek = WeekMath.startOfWeek(for: Date(), payoutDay: payoutDay)
                let weekInt = Int(startOfWeek.timeIntervalSince1970)
                let recordName = "period-\(familyRecordName)-\(profile.id.recordName)-\(weekInt)"
                if existingNames.contains(recordName) {
                    continue
                }
                if let cacheService,
                   cacheService.fetchAllowancePeriod(recordName: recordName, family: familyRecordName) != nil
                {
                    continue
                }
                let period = AllowancePeriod(
                    weekOf: startOfWeek,
                    profile: CKRecord.Reference(recordID: profile.id, action: .none),
                    questsTotal: 0,
                    family: profile.family,
                    id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
                )
                do {
                    let saved = try await cloudKit.save(period, in: zoneID, using: nil)
                    await cacheService?.upsertAllowancePeriod(saved)
                    syncCoordinator?.enqueueSave(recordID: saved.id, isOwner: isOwner)
                    created += 1
                } catch {
                    logger.warning("Failed to seed allowance period \(recordName, privacy: .private): \(error, privacy: .private)")
                }
            }
            if created > 0 {
                logger.info("Allowance period seed created \(created) rows.")
            } else {
                logger.info("No missing allowance periods to seed.")
            }
        }
    }

    /// Marker step for the V8 cache-schema bump. The schema change itself
    /// (GoalCache plus savings-config/claim/bucket fields) is an incompatible
    /// SwiftData change, so the destructive store reset + CKSyncEngine
    /// rehydration happens automatically when the container opens with V8 —
    /// this step exists so the version transition is tracked per account and
    /// family, and so any future backfill has a stable anchor to extend.
    static func schemaV8SavingsResetMarker(cloudKit: any CloudKitServiceProtocol) -> MigrationStep {
        MigrationStep(id: "SchemaV8SavingsResetMarker", version: 8) {
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "DataMigrations")
            guard cloudKit.activeFamilyZoneID != nil else {
                logger.info("No active family zone; nothing to record for schema V8.")
                return
            }
            logger.info("Schema V8 destructive cache reset handled by SwiftData container open.")
        }
    }
}
