//
//  AppLifecycleCoordinator+Reconciliation.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import CloudKit
import Foundation
import os

// MARK: - Snapshot & Cache Reconciliation

extension AppLifecycleCoordinator {
    struct FamilySnapshot: Sendable {
        let inboundRecords: [CKRecord]
        let validRecordNamesByType: [CachedRecordType: Set<String>]
        let isEmpty: Bool
    }

    struct SnapshotPartition: Sendable {
        let type: CachedRecordType
        let records: [CKRecord]
        let names: Set<String>
    }

    @MainActor
    static func fetchSnapshot(
        for recordType: CachedRecordType,
        cloudKit: any CloudKitServiceProtocol,
        familyRecordName: String,
        zoneName: String,
        ownerName: String,
        isOwner: Bool
    ) async throws -> SnapshotPartition {
        // WHY: Reconstruct non-Sendable CloudKit values on MainActor so the
        // concurrent TaskGroup only captures Sendable strings/bool.
        let zid = CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
        let db = cloudKit.database(isOwner: isOwner)
        switch recordType {
        case .quest:
            let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zid)
            let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            let models = try await cloudKit.query(Quest.self, predicate: predicate, in: zid, sortDescriptors: nil, using: db)
            let records = models.map { $0.toRecord() }
            return SnapshotPartition(type: recordType, records: records, names: Set(records.map(\.recordID.recordName)))
        case .ledgerEntry:
            let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zid)
            let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            let models = try await cloudKit.query(LedgerEntry.self, predicate: predicate, in: zid, sortDescriptors: nil, using: db)
            let records = models.map { $0.toRecord() }
            return SnapshotPartition(type: recordType, records: records, names: Set(records.map(\.recordID.recordName)))
        case .questCompletion:
            let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zid)
            let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            let models = try await cloudKit.query(QuestCompletion.self, predicate: predicate, in: zid, sortDescriptors: nil, using: db)
            let records = models.map { $0.toRecord() }
            return SnapshotPartition(type: recordType, records: records, names: Set(records.map(\.recordID.recordName)))
        case .allowancePeriod:
            let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zid)
            let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            let models = try await cloudKit.query(AllowancePeriod.self, predicate: predicate, in: zid, sortDescriptors: nil, using: db)
            let records = models.map { $0.toRecord() }
            return SnapshotPartition(type: recordType, records: records, names: Set(records.map(\.recordID.recordName)))
        case .goal:
            let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zid)
            let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            let models = try await cloudKit.query(Goal.self, predicate: predicate, in: zid, sortDescriptors: nil, using: db)
            let records = models.map { $0.toRecord() }
            return SnapshotPartition(type: recordType, records: records, names: Set(records.map(\.recordID.recordName)))
        case .profile:
            let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zid)
            let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            let models = try await cloudKit.query(Profile.self, predicate: predicate, in: zid, sortDescriptors: nil, using: db)
            let records = models.map { $0.toRecord() }
            return SnapshotPartition(type: recordType, records: records, names: Set(records.map(\.recordID.recordName)))
        case .questTemplate:
            let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zid)
            let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            let models = try await cloudKit.query(QuestTemplate.self, predicate: predicate, in: zid, sortDescriptors: nil, using: db)
            let records = models.map { $0.toRecord() }
            return SnapshotPartition(type: recordType, records: records, names: Set(records.map(\.recordID.recordName)))
        case .family:
            let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zid)
            let predicate = NSPredicate(format: "recordID == %@", familyID)
            let models = try await cloudKit.query(Family.self, predicate: predicate, in: zid, sortDescriptors: nil, using: db)
            let records = models.map { $0.toRecord() }
            return SnapshotPartition(type: recordType, records: records, names: Set(records.map(\.recordID.recordName)))
        case .achievement:
            let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zid)
            let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            let models = try await cloudKit.query(Achievement.self, predicate: predicate, in: zid, sortDescriptors: nil, using: db)
            let records = models.map { $0.toRecord() }
            return SnapshotPartition(type: recordType, records: records, names: Set(records.map(\.recordID.recordName)))
        case .profileAchievement:
            let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zid)
            let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            let models = try await cloudKit.query(ProfileAchievement.self, predicate: predicate, in: zid, sortDescriptors: nil, using: db)
            let records = models.map { $0.toRecord() }
            return SnapshotPartition(type: recordType, records: records, names: Set(records.map(\.recordID.recordName)))
        case .notificationPreference:
            let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zid)
            let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            let models = try await cloudKit.query(NotificationPreference.self, predicate: predicate, in: zid, sortDescriptors: nil, using: db)
            let records = models.map { $0.toRecord() }
            return SnapshotPartition(type: recordType, records: records, names: Set(records.map(\.recordID.recordName)))
        case .gemLedger:
            let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zid)
            let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            let models = try await cloudKit.query(GemLedger.self, predicate: predicate, in: zid, sortDescriptors: nil, using: db)
            let records = models.map { $0.toRecord() }
            return SnapshotPartition(type: recordType, records: records, names: Set(records.map(\.recordID.recordName)))
        case .rewardEvent:
            let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zid)
            let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            let models = try await cloudKit.query(RewardEvent.self, predicate: predicate, in: zid, sortDescriptors: nil, using: db)
            let records = models.map { $0.toRecord() }
            return SnapshotPartition(type: recordType, records: records, names: Set(records.map(\.recordID.recordName)))
        }
    }

    private func fetchFamilySnapshot(family: Family, zoneID: CKRecordZone.ID, isOwner: Bool) async throws -> FamilySnapshot {
        let familyRecordName = family.id.recordName
        let zoneName = zoneID.zoneName
        let ownerName = zoneID.ownerName
        let isOwnerCopy = isOwner
        let cloudKitServiceCopy = cloudKitService

        var inboundRecords: [CKRecord] = []
        inboundRecords.reserveCapacity(256)
        var validRecordNamesByType: [CachedRecordType: Set<String>] = [:]

        let recordTypes: [CachedRecordType] = [
            .quest, .ledgerEntry, .questCompletion, .allowancePeriod,
            .goal, .profile, .questTemplate, .family,
            .achievement, .profileAchievement, .notificationPreference,
            .gemLedger, .rewardEvent
        ]

        try await withThrowingTaskGroup(of: SnapshotPartition.self) { group in
            for type in recordTypes {
                group.addTask {
                    try await Self.fetchSnapshot(
                        for: type,
                        cloudKit: cloudKitServiceCopy,
                        familyRecordName: familyRecordName,
                        zoneName: zoneName,
                        ownerName: ownerName,
                        isOwner: isOwnerCopy
                    )
                }
            }

            for try await partition in group {
                inboundRecords.append(contentsOf: partition.records)
                validRecordNamesByType[partition.type] = partition.names
            }
        }

        let isEmpty = validRecordNamesByType.values.allSatisfy(\.isEmpty)

        return FamilySnapshot(
            inboundRecords: inboundRecords,
            validRecordNamesByType: validRecordNamesByType,
            isEmpty: isEmpty
        )
    }

    func reconcileCacheFromCloudKit() async {
        guard let appState,
              let family = appState.family,
              let zoneID = appState.familyZoneID
        else {
            return
        }

        let isOwner = appState.isZoneOwner
        do {
            let snapshot = try await fetchFamilySnapshot(family: family, zoneID: zoneID, isOwner: isOwner)

            guard !snapshot.isEmpty else {
                logger.warning(
                    "Cache reconciliation aborted: empty snapshot — pruning skipped to preserve pending rows",
                    family: family.id.recordName,
                    zone: zoneID.zoneName
                )
                return
            }

            if !isOwner, let backgroundCache = appState.backgroundCacheActor {
                guard let outcome = await backgroundCache.reconcileParticipantSet(
                    records: snapshot.inboundRecords,
                    validRecordNamesByType: snapshot.validRecordNamesByType,
                    familyRecordName: family.id.recordName,
                    databaseScope: .shared,
                    zoneID: zoneID
                )
                else { return }

                if !outcome.commitSucceeded {
                    logger.error(
                        "Participant cache reconciliation commit failed; \(outcome.recordCount) record(s) left for the next pass",
                        family: family.id.recordName,
                        zone: zoneID.zoneName
                    )
                } else if outcome.parseFailures > 0 {
                    logger.warning(
                        "Participant cache reconciliation dropped \(outcome.parseFailures) unparseable record(s)",
                        family: family.id.recordName,
                        zone: zoneID.zoneName
                    )
                }
            } else if let concrete = syncCoordinator as? CKSyncEngineCoordinator {
                await concrete.delegateHandler.handleIncomingRecordsDirectly(
                    snapshot.inboundRecords,
                    databaseScope: .private,
                    zoneID: zoneID
                )
            } else if let backgroundCache = appState.backgroundCacheActor {
                let parsed = snapshot.inboundRecords.map { ParsedRecord.parse(record: $0) }
                await backgroundCache.batchUpsertParsedRecords(parsed)
            }
            // Track push age for debug overlay — completion of the snapshot
            // reconciliation pass represents a successful push-driven refresh.
            if let concrete = syncCoordinator as? CKSyncEngineCoordinator {
                concrete.notePushReceived()
            }
        } catch {
            logger.error(
                "Cache reconciliation failed: \(error)",
                family: family.id.recordName,
                zone: zoneID.zoneName
            )
        }
    }
}

private extension Logger {
    func warning(_ message: String, family: String, zone: String) {
        log(level: .default, "\(message, privacy: .public) family=\(family, privacy: .private) zone=\(zone, privacy: .private)")
    }

    func info(_ message: String, family: String, zone: String) {
        log(level: .info, "\(message, privacy: .public) family=\(family, privacy: .private) zone=\(zone, privacy: .private)")
    }

    func error(_ message: String, family: String, zone: String) {
        log(level: .error, "\(message, privacy: .public) family=\(family, privacy: .private) zone=\(zone, privacy: .private)")
    }
}
