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
    // WHY no owner backfill: unresolved anchors deny, legacy dev rows need zone wipe/re-create, never patched ad-hoc.
    private let logger = Logger(category: "DataMigrations")
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
    @MainActor
    private static func migrationScope(appState: AppState?, cloudKit: any CloudKitServiceProtocol) -> CKDatabase.Scope? {
        if let scope = DatabaseScopeResolver.resolvedScope(appState: appState) {
            return scope
        }
        // WHY test seam: coordinator doubles omit session, so infer from engine flag in tests.
        if TestEnvironment.isRunningUnitOrUITests, let zoneID = cloudKit.activeFamilyZoneID {
            if let inferred = inferDatabaseScope(from: zoneID) {
                return inferred == "private" ? .private : .shared
            }
            return DatabaseScopeResolver.scope(isOwner: cloudKit.activeIsOwner)
        }
        return nil
    }

    static func questNameBackfillV1(
        cloudKit: any CloudKitServiceProtocol,
        appState: AppState? = nil,
        syncCoordinator: (any SyncEnqueuing)? = nil
    ) -> MigrationStep {
        MigrationStep(id: "QuestNameBackfillV1", version: 1) {
            let logger = Logger(category: "DataMigrations")
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
            // WHY dedupe by template so shared templates fetch once, not once per quest.
            let templateNames = Set(needsBackfill.map(\.template.recordID.recordName))
            // WHY concurrent fetch collapses N sequential round-trips into one batched phase; missing templates resolve to nil fallback while hard errors abort before any write.
            let templatesByName: [String: QuestTemplate]
            do {
                templatesByName = try await withThrowingTaskGroup(of: (String, QuestTemplate?).self, returning: [String: QuestTemplate].self) { group in
                    for templateName in templateNames {
                        group.addTask {
                            let templateID = CKRecord.ID(recordName: templateName, zoneID: activeZone)
                            let template = try await fetchRecordOrNil(
                                QuestTemplate.self,
                                id: templateID,
                                cloudKit: cloudKit
                            )
                            return (templateName, template)
                        }
                    }
                    var collected: [String: QuestTemplate] = [:]
                    collected.reserveCapacity(templateNames.count)
                    for try await (templateName, template) in group {
                        if let template {
                            collected[templateName] = template
                        }
                    }
                    return collected
                }
            } catch {
                logger.error("Template batch fetch failed, aborting quest name backfill before writes: \(error, privacy: .private)")
                throw error
            }
            var updatedQuests: [Quest] = []
            updatedQuests.reserveCapacity(needsBackfill.count)
            for quest in needsBackfill {
                var updated = quest
                if let template = templatesByName[quest.template.recordID.recordName] {
                    updated.name = template.name
                } else {
                    logger.warning("Template missing for quest \(quest.id.recordName, privacy: .private); reconciling with fallback title.")
                    updated.name = "Quest"
                }
                updatedQuests.append(updated)
            }
            // WHY concurrent saves collapse N sequential writes into one batched phase; failures collect then throw so the versioned flag retries the remainder instead of marking
            // partial success complete.
            var failedRecordNames: [String] = []
            var savedQuests: [Quest] = []
            savedQuests.reserveCapacity(updatedQuests.count)
            await withTaskGroup(of: (Quest?, String?).self) { group in
                for quest in updatedQuests {
                    group.addTask {
                        do {
                            let saved = try await cloudKit.save(quest)
                            return (saved, nil)
                        } catch {
                            logger.error("Failed to backfill quest \(quest.id.recordName, privacy: .private): \(error, privacy: .private)")
                            return (nil, quest.id.recordName)
                        }
                    }
                }
                for await (saved, failed) in group {
                    if let saved {
                        savedQuests.append(saved)
                    }
                    if let failed {
                        failedRecordNames.append(failed)
                    }
                }
            }
            // WHY ingest: one-shot server echo rides the single door without stamping freshness; versioned flag guards single use.
            if let syncCoordinator, !savedQuests.isEmpty, let scope = migrationScope(appState: appState, cloudKit: cloudKit) {
                await syncCoordinator.hydrationHandler.hydrateFromQuery(models: savedQuests, databaseScope: scope, zoneID: activeZone)
            }
            if !failedRecordNames.isEmpty {
                throw MigrationError.incompleteBackfill("Quest name backfill had save errors; migration marked incomplete for retry")
            }
        }
    }

    static func questTargetCountBackfillV2(backgroundCache: BackgroundCacheActor) -> MigrationStep {
        MigrationStep(id: "QuestTargetCountBackfillV2", version: 2) {
            await backgroundCache.backfillTargetCountGlobally()
        }
    }

    static func questLedgerBackfillV1(
        cloudKit: any CloudKitServiceProtocol,
        cacheService _: CacheService? = nil,
        appState: AppState? = nil,
        syncCoordinator: (any SyncEnqueuing)? = nil
    ) -> MigrationStep {
        MigrationStep(id: "QuestLedgerBackfillV1", version: 1) {
            let logger = Logger(category: "DataMigrations")
            guard let zoneID = cloudKit.activeFamilyZoneID else {
                logger.info("No active family zone, skipping ledger backfill.")
                return
            }
            // WHY ingest-only: one-shot server echo rides the single door without stamping freshness; versioned flag plus deterministic payout IDs keep re-runs idempotent.
            let hydrateScope = migrationScope(appState: appState, cloudKit: cloudKit)
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
                    entryRecordName = DeterministicRecordID.payout(periodRecordName: period.id.recordName)
                    descriptionPrefix = "Quest earnings"
                    let rtID = CKRecord.ID(recordName: DeterministicRecordID.realtimePayout(periodRecordName: period.id.recordName), zoneID: zoneID)
                    let realTimeEntry = try await fetchRecordOrNil(
                        LedgerEntry.self,
                        id: rtID,
                        cloudKit: cloudKit
                    )
                    if realTimeEntry != nil {
                        continue
                    }
                    let weekEnd = WeekMath.weekRange(starting: period.weekOf).upperBound
                    let depositBonusSum = existingLedgers
                        .filter {
                            $0.profile.recordID == period.profile.recordID &&
                                $0.source != "quest" &&
                                $0.amount > 0 &&
                                $0.date >= period.weekOf &&
                                $0.date < weekEnd
                        }
                        .reduce(0) { $0 + $1.amount }
                    paidAmount = max(0, paidAmount - depositBonusSum)
                    guard paidAmount > 0 else { continue }
                } else {
                    entryRecordName = DeterministicRecordID.realtimePayout(periodRecordName: period.id.recordName)
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
                if let syncCoordinator, let hydrateScope {
                    await syncCoordinator.hydrationHandler.hydrateFromQuery(models: [saved], databaseScope: hydrateScope, zoneID: zoneID)
                }
            }
        }
    }

    static func achievementMigrationV1(
        cloudKit: any CloudKitServiceProtocol,
        cacheService _: CacheService? = nil,
        appState: AppState? = nil,
        syncCoordinator: (any SyncEnqueuing)? = nil
    ) -> MigrationStep {
        MigrationStep(id: "AchievementMigrationV1", version: 1) {
            let logger = Logger(category: "DataMigrations")
            guard let zoneID = cloudKit.activeFamilyZoneID else {
                logger.info("No active family zone, skipping achievement migration.")
                return
            }
            // WHY ingest-only: one-shot canonical echo rides the single door without stamping freshness; versioned flag plus deterministic family-requirement IDs keep re-runs
            // idempotent.
            let hydrateScope = migrationScope(appState: appState, cloudKit: cloudKit)
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
                    if let syncCoordinator, let hydrateScope {
                        await syncCoordinator.hydrationHandler.hydrateFromQuery(models: [saved], databaseScope: hydrateScope, zoneID: zoneID)
                    }
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
        cacheService _: CacheService? = nil,
        syncCoordinator: (any SyncEnqueuing)? = nil,
        appState: AppState? = nil
    ) -> MigrationStep {
        MigrationStep(id: "heroNotificationPreferenceBackfillV1", version: 1) {
            let logger = Logger(category: "DataMigrations")
            guard let zoneID = cloudKit.activeFamilyZoneID else {
                logger.info("No active family zone, skipping notification preference backfill.")
                return
            }
            // WHY fail-closed: unknown scope drops so tokens re-deliver instead of guessing a database.
            guard let scope = migrationScope(appState: appState, cloudKit: cloudKit) else { return }
            let familyRecordName = zoneID.zoneName
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
            let isOwner = ActiveFamilyScopeGuard.correctedIsOwner(appState: appState, logger: logger, context: "DataMigrations.heroNotificationPreferenceBackfillV1")
            for pref in toCreate {
                do {
                    let saved = try await cloudKit.save(pref, in: zoneID, using: nil)
                    // WHY ingest: one-shot server echo rides the single door without stamping freshness; versioned flag guards single use.
                    await syncCoordinator?.hydrationHandler.hydrateFromQuery(models: [saved], databaseScope: scope, zoneID: zoneID)
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
        syncCoordinator: (any SyncEnqueuing)? = nil,
        appState: AppState? = nil
    ) -> MigrationStep {
        MigrationStep(id: "allowancePeriodSeedV1", version: 1) {
            let logger = Logger(category: "DataMigrations")
            guard let zoneID = cloudKit.activeFamilyZoneID else {
                logger.info("No active family zone, skipping allowance period seed.")
                return
            }
            let familyRecordName = zoneID.zoneName
            let family: Family? = if let cached = cacheService?.fetchFamily(recordName: familyRecordName) {
                cached.toFamily(zoneID: zoneID)
            } else {
                try await fetchRecordOrNil(Family.self, id: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), cloudKit: cloudKit)
            }
            let profiles = try await cloudKit.query(Profile.self, predicate: NSPredicate(value: true), in: zoneID)
            let activeHeroes = profiles.filter { $0.isActive && $0.role == .hero }
            guard !activeHeroes.isEmpty else {
                logger.info("No active heroes for allowance period seed.")
                return
            }
            let existingPeriods = try await cloudKit.query(AllowancePeriod.self, predicate: NSPredicate(value: true), in: zoneID)
            let existingNames = Set(existingPeriods.map(\.id.recordName))
            var created = 0
            for profile in activeHeroes {
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
                // WHY fail-closed: unknown scope drops hydrate/enqueue so tokens re-deliver instead of guessing.
                guard let scope = migrationScope(appState: appState, cloudKit: cloudKit) else { continue }
                let isOwner = ActiveFamilyScopeGuard.correctedIsOwner(appState: appState, logger: logger, context: "DataMigrations.allowancePeriodSeedV1")
                let period = AllowancePeriod(
                    weekOf: startOfWeek,
                    profile: CKRecord.Reference(recordID: profile.id, action: .none),
                    questsTotal: 0,
                    family: profile.family,
                    id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
                )
                do {
                    let saved = try await cloudKit.save(period, in: zoneID, using: nil)
                    created += 1
                    // WHY ingest: one-shot server echo rides the single door without stamping freshness; versioned flag guards single use.
                    await syncCoordinator?.hydrationHandler.hydrateFromQuery(models: [saved], databaseScope: scope, zoneID: zoneID)
                    syncCoordinator?.enqueueSave(recordID: saved.id, isOwner: isOwner)
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

    /// Marker step for the V8 cache-schema bump. The schema change itself (GoalCache plus
    /// savings-config/claim/bucket fields) is an incompatible SwiftData change, so the destructive store
    static func schemaV8SavingsResetMarker(cloudKit: any CloudKitServiceProtocol) -> MigrationStep {
        MigrationStep(id: "SchemaV8SavingsResetMarker", version: 8) {
            let logger = Logger(category: "DataMigrations")
            guard cloudKit.activeFamilyZoneID != nil else {
                logger.info("No active family zone; nothing to record for schema V8.")
                return
            }
            logger.info("Schema V8 destructive cache reset handled by SwiftData container open.")
        }
    }

    /// Marker step for the V10 cache-schema bump. V10 is an index-only change
    /// (LedgerEntryCache adds two composite indexes). No properties added/removed, no data backfill.
    /// The store upgrade attempts lightweight with destructive-reset fallback in `CacheService` on failure;
    /// the marker only records that the transition was observed per account+family.
    /// Fail-open without an active zone mirrors V8.
    static func schemaV10LedgerIndexMarker(cloudKit: any CloudKitServiceProtocol) -> MigrationStep {
        MigrationStep(id: "SchemaV10LedgerIndexMarker", version: 10) {
            let logger = Logger(category: "DataMigrations")
            guard cloudKit.activeFamilyZoneID != nil else {
                logger.info("No active family zone; nothing to record for schema V10.")
                return
            }
            logger.info("Schema V10 lightweight index migration handled by SwiftData container open.")
        }
    }

    /// Cleans up any legacy allowance periods mistakenly seeded for parent profiles.
    static func purgeParentAllowancePeriodsV1(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService?,
        syncCoordinator: (any SyncEnqueuing)? = nil,
        appState: AppState? = nil
    ) -> MigrationStep {
        MigrationStep(id: "purgeParentAllowancePeriodsV1", version: 1) {
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "DataMigrations")
            guard let zoneID = cloudKit.activeFamilyZoneID else {
                logger.info("No active family zone, skipping purge parent allowance periods.")
                return
            }
            let familyRecordName = zoneID.zoneName

            let profiles = try await cloudKit.query(Profile.self, predicate: NSPredicate(value: true), in: zoneID)
            let parentProfileRecordNames = Set(profiles.filter(\.role.isParent).map(\.id.recordName))
            guard !parentProfileRecordNames.isEmpty else { return }

            let existingPeriods = try await cloudKit.query(AllowancePeriod.self, predicate: NSPredicate(value: true), in: zoneID)
            let parentPeriods = existingPeriods.filter { parentProfileRecordNames.contains($0.profile.recordID.recordName) }
            guard !parentPeriods.isEmpty else { return }

            var deleted = 0
            for period in parentPeriods {
                // WHY canonical: single delete path keeps the tombstone alive across row removal.
                guard let cacheService else { continue }
                await ActiveFamilyScopeGuard.deleteAndEnqueue(
                    cacheService: cacheService,
                    target: ActiveFamilyScopeGuard.ScopedDeleteTarget(recordID: period.id, familyRecordName: familyRecordName),
                    type: .allowancePeriod,
                    deleteContext: ActiveFamilyScopeGuard.ScopedDeleteContext(
                        coordinator: syncCoordinator,
                        appState: appState,
                        logger: logger,
                        context: "DataMigrations.purgeParentAllowancePeriodsV1",
                        expectedActiveZone: zoneID
                    )
                )
                deleted += 1
            }
            if deleted > 0 {
                logger.info("Purged \(deleted) parent allowance periods.")
            }
        }
    }

    /// WHY pennies: domain round-trip converges idempotently; versioned flag prevents reruns.
    static func currencyToPenniesV1(
        cloudKit: any CloudKitServiceProtocol,
        cacheService _: CacheService? = nil,
        syncCoordinator: (any SyncEnqueuing)? = nil,
        appState: AppState? = nil
    ) -> MigrationStep {
        MigrationStep(id: "CurrencyToPenniesV1", version: 1) {
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "DataMigrations")
            guard let zoneID = cloudKit.activeFamilyZoneID else {
                logger.info("No active family zone, skipping currency to pennies migration.")
                return
            }
            // WHY fail-closed: unknown scope drops so tokens re-deliver instead of guessing a database.
            guard let scope = migrationScope(appState: appState, cloudKit: cloudKit) else { return }
            let isOwner = ActiveFamilyScopeGuard.correctedIsOwner(appState: appState, logger: logger, context: "DataMigrations.currencyToPenniesV1")
            var converted = 0
            var hadFailures = false

            // WHY domain round-trip: init(record:) coerces legacy Double
            // dollars via dollarsToPennies (round half up) while Int64 rows
            // pass through unchanged, so re-saving converges idempotently.
            // WHY save-all: the typed query erases Double-vs-Int encoding, so
            // every row rewrites deterministically; values converge and the
            // versioned flag keeps reruns from repeating the pass.
            let allowanceResult = await convertRecords(
                AllowancePeriod.self,
                cloudKit: cloudKit,
                zoneID: zoneID,
                scope: scope,
                isOwner: isOwner,
                syncCoordinator: syncCoordinator,
                logger: logger
            )
            converted += allowanceResult.converted
            hadFailures = hadFailures || allowanceResult.hadFailures

            let ledgerResult = await convertRecords(
                LedgerEntry.self,
                cloudKit: cloudKit,
                zoneID: zoneID,
                scope: scope,
                isOwner: isOwner,
                syncCoordinator: syncCoordinator,
                logger: logger
            )
            converted += ledgerResult.converted
            hadFailures = hadFailures || ledgerResult.hadFailures

            let questResult = await convertRecords(
                Quest.self,
                cloudKit: cloudKit,
                zoneID: zoneID,
                scope: scope,
                isOwner: isOwner,
                syncCoordinator: syncCoordinator,
                logger: logger
            )
            converted += questResult.converted
            hadFailures = hadFailures || questResult.hadFailures

            let templateResult = await convertRecords(
                QuestTemplate.self,
                cloudKit: cloudKit,
                zoneID: zoneID,
                scope: scope,
                isOwner: isOwner,
                syncCoordinator: syncCoordinator,
                logger: logger
            )
            converted += templateResult.converted
            hadFailures = hadFailures || templateResult.hadFailures

            let rewardResult = await convertRecords(
                RewardEvent.self,
                cloudKit: cloudKit,
                zoneID: zoneID,
                scope: scope,
                isOwner: isOwner,
                syncCoordinator: syncCoordinator,
                logger: logger
            )
            converted += rewardResult.converted
            hadFailures = hadFailures || rewardResult.hadFailures

            if hadFailures {
                throw MigrationError.incompleteBackfill("Currency to pennies had save errors; migration marked incomplete for retry")
            }
            logger.info("Currency to pennies migration converted \(converted) records.")
        }
    }

    @discardableResult
    private static func convertRecords<T: CloudKitRecord>(
        _ type: T.Type,
        cloudKit: any CloudKitServiceProtocol,
        zoneID: CKRecordZone.ID,
        scope: CKDatabase.Scope,
        isOwner: Bool,
        syncCoordinator: (any SyncEnqueuing)?,
        logger: Logger
    ) async -> (converted: Int, hadFailures: Bool) where T.ID == CKRecord.ID {
        var converted = 0
        var hadFailures = false
        do {
            let records = try await cloudKit.query(type, predicate: NSPredicate(value: true), in: zoneID)
            for record in records {
                do {
                    let saved = try await cloudKit.save(record, in: zoneID, using: nil)
                    // WHY ingest: one-shot server echo rides the single door without stamping freshness; versioned flag guards single use.
                    await syncCoordinator?.hydrationHandler.hydrateFromQuery(models: [saved], databaseScope: scope, zoneID: zoneID)
                    syncCoordinator?.enqueueSave(recordID: saved.id, isOwner: isOwner)
                    converted += 1
                } catch {
                    logger.error("Failed to convert \(String(describing: type)) \(record.id.recordName, privacy: .private): \(error, privacy: .private)")
                    hadFailures = true
                }
            }
        } catch {
            logger.error("Currency migration \(String(describing: type)) query failed: \(error, privacy: .private)")
            hadFailures = true
        }
        return (converted, hadFailures)
    }
}
