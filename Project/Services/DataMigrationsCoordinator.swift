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
            logger.info("Migrations already in flight for \(lockKey), skipping.")
            return
        }
        inFlightFamilyKeys.insert(lockKey)
        defer { inFlightFamilyKeys.remove(lockKey) }

        for step in steps {
            let key = "migration.\(accountID).\(familyRecordName).\(step.id).v\(step.version).complete"
            guard !defaults.bool(forKey: key) else {
                logger.debug("Migration \(step.id) v\(step.version) already complete for \(lockKey), skipping")
                continue
            }

            logger.info("Running migration: \(step.id) v\(step.version) for \(lockKey)")
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
            // Guard: Must have an active family zone to backfill quests from
            guard let activeZone = cloudKit.activeFamilyZoneID else {
                logger.info("No active family zone, skipping quest name backfill.")
                return
            }

            // Query all Quests
            let allQuests = try await cloudKit.query(Quest.self, predicate: NSPredicate(value: true), in: activeZone)

            // Filter to those with nil name and non-nil template
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
                        logger.warning("Template missing for quest \(quest.id.recordName); reconciling with fallback title.")
                        updated.name = "Quest"
                    }
                    _ = try await cloudKit.save(updated)
                } catch {
                    logger.error("Failed to backfill quest \(quest.id.recordName): \(error, privacy: .private)")
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
            // Backfill `targetCount` to 1 for any QuestCache or QuestTemplateCache
            // rows persisted before the field existed. Iterates globally across all
            // cached rows (not per-family) so pre-feature installs across every
            // family zone are repaired in one pass. The backfill is idempotent —
            // rows already carrying a positive value are never clobbered. Safe to run on BackgroundCacheActor.
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

            // Backfill every allowance period — paid and open. The ledger is
            // the single source of truth for wallet balances, so pre-update
            // quest earnings must survive the migration even when the period
            // was never closed: real-time heroes accumulate paidAmount while
            // the period stays open, and unpaid perQuest histories carry
            // totalEarned with no payout entry.
            let periods = try await cloudKit.query(
                AllowancePeriod.self,
                predicate: NSPredicate(value: true)
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

                    // Real-time heroes already settled each week's earnings into
                    // an "rt-" entry; minting a payout entry over it would total
                    // the week's quest earnings twice in currentBalance.
                    let rtID = CKRecord.ID(recordName: "rt-\(period.id.recordName)", zoneID: zoneID)
                    let realTimeEntry = try await fetchRecordOrNil(
                        LedgerEntry.self,
                        id: rtID,
                        cloudKit: cloudKit
                    )
                    if realTimeEntry != nil {
                        continue
                    }

                    // For legacy paid periods created under earlier app versions,
                    // paidAmount included manual deposit bonus gold. Subtract any
                    // existing non-quest deposit entries for that week so bonus gold
                    // is not double-counted in currentBalance.
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
                    // Open/never-paid periods mint the real-time "rt-" entry so
                    // their accumulated earnings do not vanish from the wallet.
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
                cacheService?.upsertLedgerEntry(saved)
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
                    cacheService?.upsertAchievement(saved)

                    try? await cloudKit.delete(achievement.id, in: zoneID, using: nil)
                    logger.info("Migrated legacy achievement \(achievement.id.recordName) to canonical \(canonicalID.recordName)")
                }
            }
        }
    }
}
