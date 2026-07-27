//
//  DataMigrationsCoordinator.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

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
    static func questNameBackfillV1(cloudKit: CloudKitService) -> MigrationStep {
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
}
