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

    struct MigrationStep {
        let id: String
        let version: Int
        let run: () async throws -> Void
    }

    private var steps: [MigrationStep] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func register(_ step: MigrationStep) {
        steps.append(step)
    }

    func runPendingMigrations() async {
        for step in steps {
            let key = "migration.\(step.id).v\(step.version).complete"
            guard !defaults.bool(forKey: key) else {
                logger.debug("Migration \(step.id) v\(step.version) already complete, skipping")
                continue
            }

            logger.info("Running migration: \(step.id) v\(step.version)")
            do {
                try await step.run()
                defaults.set(true, forKey: key)
                logger.info("Migration \(step.id) v\(step.version) completed successfully")
            } catch {
                logger.error("Migration \(step.id) v\(step.version) failed: \(error, privacy: .private)")
            }
        }
    }
}

// MARK: - Migration Steps

extension DataMigrationsCoordinator {
    static func questNameBackfillV1(cloudKit: any CloudKitServiceProtocol) -> MigrationStep {
        MigrationStep(id: "QuestNameBackfillV1", version: 1) {
            // Guard: Must have an active family zone to backfill quests from
            guard cloudKit.activeFamilyZoneID != nil else { return }

            // Query all Quests
            let allQuests = try await cloudKit.query(Quest.self, predicate: NSPredicate(value: true))

            // Filter to those with nil name and non-nil template
            let needsBackfill = allQuests.filter { $0.name == nil }
            guard !needsBackfill.isEmpty else { return }

            for quest in needsBackfill {
                // Resolve the template
                guard let template = try? await cloudKit.fetch(
                    QuestTemplate.self,
                    id: quest.template.recordID
                ) else {
                    continue // Template not found — skip this quest
                }

                // Stamp the name
                var updated = quest
                updated.name = template.name
                _ = try await cloudKit.save(updated)
            }
        }
    }

    static func questTargetCountBackfillV2(backgroundCache: BackgroundCacheActor) -> MigrationStep {
        MigrationStep(id: "QuestTargetCountBackfillV2", version: 2) {
            // Backfill `targetCount` to 1 for any QuestCache or QuestTemplateCache
            // rows persisted before the field existed. Iterates globally by
            // `@Attribute(.unique) recordName` (not per-family) so pre-feature
            // installs across every family zone are repaired in one pass. The
            // backfill is idempotent — rows already carrying a positive value
            // are never clobbered. Safe to run on BackgroundCacheActor.
            await backgroundCache.backfillTargetCountGlobally()
        }
    }

    static func questLedgerBackfillV1(cloudKit: any CloudKitServiceProtocol, cacheService: CacheService?) -> MigrationStep {
        MigrationStep(id: "QuestLedgerBackfillV1", version: 1) {
            guard let zoneID = cloudKit.activeFamilyZoneID else { return }

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

            let existingLedgers = await (try? cloudKit.query(
                LedgerEntry.self,
                predicate: NSPredicate(value: true),
                in: zoneID
            )) ?? []

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
                    let realTimeEntryExists = await (try? cloudKit.fetch(
                        LedgerEntry.self,
                        id: CKRecord.ID(recordName: "rt-\(period.id.recordName)", zoneID: zoneID)
                    )) != nil
                    if realTimeEntryExists {
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

                let existing = try? await cloudKit.fetch(LedgerEntry.self, id: CKRecord.ID(recordName: entryRecordName, zoneID: zoneID))
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
                    id: CKRecord.ID(recordName: entryRecordName, zoneID: zoneID)
                )
                cacheService?.upsertLedgerEntry(entry)
                if let saved = try? await cloudKit.save(entry, in: zoneID, using: nil) {
                    cacheService?.upsertLedgerEntry(saved)
                }
            }
        }
    }
}
