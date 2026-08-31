//
//  AppLifecycleCoordinator+Reconciliation.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import CloudKit
import Foundation
import os

// WHY: Swift 6 strict concurrency — `CloudKitServiceProtocol` is `@MainActor`-isolated and
// `CKRecord` may not be `Sendable` in the current SDK. Boxing allows a `Sendable` value
// to cross the `TaskGroup` `@Sendable` boundary safely; the wrapped value is only
// unwrapped on `MainActor` where isolation is re-established.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

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
            return try await fetchAndBridge(Quest.self, familyRecordName: familyRecordName, zid: zid, db: db, cloudKit: cloudKit)
        case .ledgerEntry:
            return try await fetchAndBridge(LedgerEntry.self, familyRecordName: familyRecordName, zid: zid, db: db, cloudKit: cloudKit)
        case .questCompletion:
            return try await fetchAndBridge(QuestCompletion.self, familyRecordName: familyRecordName, zid: zid, db: db, cloudKit: cloudKit)
        case .allowancePeriod:
            return try await fetchAndBridge(AllowancePeriod.self, familyRecordName: familyRecordName, zid: zid, db: db, cloudKit: cloudKit)
        case .goal:
            return try await fetchAndBridge(Goal.self, familyRecordName: familyRecordName, zid: zid, db: db, cloudKit: cloudKit)
        case .profile:
            return try await fetchAndBridge(Profile.self, familyRecordName: familyRecordName, zid: zid, db: db, cloudKit: cloudKit)
        case .questTemplate:
            return try await fetchAndBridge(QuestTemplate.self, familyRecordName: familyRecordName, zid: zid, db: db, cloudKit: cloudKit)
        case .family:
            return try await fetchAndBridge(Family.self, familyRecordName: familyRecordName, zid: zid, db: db, cloudKit: cloudKit)
        case .achievement:
            return try await fetchAndBridge(Achievement.self, familyRecordName: familyRecordName, zid: zid, db: db, cloudKit: cloudKit)
        case .profileAchievement:
            return try await fetchAndBridge(ProfileAchievement.self, familyRecordName: familyRecordName, zid: zid, db: db, cloudKit: cloudKit)
        case .notificationPreference:
            return try await fetchAndBridge(NotificationPreference.self, familyRecordName: familyRecordName, zid: zid, db: db, cloudKit: cloudKit)
        case .gemLedger:
            return try await fetchAndBridge(GemLedger.self, familyRecordName: familyRecordName, zid: zid, db: db, cloudKit: cloudKit)
        case .rewardEvent:
            return try await fetchAndBridge(RewardEvent.self, familyRecordName: familyRecordName, zid: zid, db: db, cloudKit: cloudKit)
        }
    }

    // WHY: Single generic query path prevents drift across the 13 family-scoped types.
    private static func fetchAndBridge<T: CloudKitRecord>(_: T.Type, familyRecordName: String, zid: CKRecordZone.ID, db: CKDatabase?,
                                                          cloudKit: any CloudKitServiceProtocol) async throws -> SnapshotPartition
    {
        let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zid)
        let predicate: NSPredicate
        if T.recordType == Family.recordType {
            // WHY: Family is the zone root — filter by recordID, not family reference.
            predicate = NSPredicate(format: "recordID == %@", familyID)
        } else {
            let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
            predicate = NSPredicate(format: "family == %@", familyRef)
        }
        let models = try await cloudKit.query(T.self, predicate: predicate, in: zid, sortDescriptors: nil, using: db)
        let records = models.map { $0.toRecord() }
        guard let cachedType = CachedRecordType.recordType(for: T.recordType) else {
            throw CloudKitServiceError.underlying("Unknown record type \(T.recordType)")
        }
        return SnapshotPartition(type: cachedType, records: records, names: Set(records.map(\.recordID.recordName)))
    }

    private func fetchFamilySnapshot(family: Family, zoneID: CKRecordZone.ID, isOwner: Bool) async -> FamilySnapshot {
        let familyRecordName = family.id.recordName
        let zoneName = zoneID.zoneName
        let ownerName = zoneID.ownerName
        let isOwnerCopy = isOwner
        // WHY: `cloudKitService` is `@MainActor`-isolated — capturing it directly in the
        // `@Sendable` `TaskGroup` closure breaches strict-concurrency actor isolation.
        // Box it as `Sendable` and only unwrap inside `Task { @MainActor in }` where
        // the `@MainActor` `fetchSnapshot` witness can be called safely. Only Sendable
        // strings/bool and the boxed service cross the Sendable boundary.
        let serviceBox = UncheckedSendableBox(value: cloudKitService)
        let snapshotLogger = logger

        var inboundRecords: [CKRecord] = []
        inboundRecords.reserveCapacity(256)
        var validRecordNamesByType: [CachedRecordType: Set<String>] = [:]

        let recordTypes: [CachedRecordType] = [
            .quest, .ledgerEntry, .questCompletion, .allowancePeriod,
            .goal, .profile, .questTemplate, .family,
            .achievement, .profileAchievement, .notificationPreference,
            .gemLedger, .rewardEvent
        ]

        await withTaskGroup(of: SnapshotPartition?.self) { group in
            for type in recordTypes {
                group.addTask {
                    do {
                        // WHY: Hop to MainActor so the `@MainActor`-isolated service
                        // and `fetchSnapshot` are never captured off-actor. The outer
                        // `@Sendable` closure captures only Sendable values and the
                        // boxed service handle; `Task { @MainActor in }` provides an
                        // async-compatible isolation hop (MainActor.run requires a
                        // synchronous closure).
                        return try await Task { @MainActor in
                            try await Self.fetchSnapshot(
                                for: type,
                                cloudKit: serviceBox.value,
                                familyRecordName: familyRecordName,
                                zoneName: zoneName,
                                ownerName: ownerName,
                                isOwner: isOwnerCopy
                            )
                        }.value
                    } catch {
                        snapshotLogger.warning(
                            "Snapshot fetch failed for \(type.rawValue): \(error.localizedDescription)",
                            family: familyRecordName,
                            zone: zoneName
                        )
                        return nil
                    }
                }
            }

            for await partition in group {
                guard let partition else { continue }
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
        let snapshot = await fetchFamilySnapshot(family: family, zoneID: zoneID, isOwner: isOwner)

        guard !snapshot.isEmpty else {
            logger.warning(
                "Cache reconciliation aborted: empty snapshot — pruning skipped to preserve pending rows",
                family: family.id.recordName,
                zone: zoneID.zoneName
            )
            return
        }

        let succeededTypes = Set(snapshot.validRecordNamesByType.keys)

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
            } else {
                if outcome.parseFailures > 0 {
                    logger.warning(
                        "Participant cache reconciliation dropped \(outcome.parseFailures) unparseable record(s)",
                        family: family.id.recordName,
                        zone: zoneID.zoneName
                    )
                }
                // Stamp freshness only for types that fetched successfully — failed types keep existing cache.
                if let concrete = syncCoordinator as? CKSyncEngineCoordinator {
                    concrete.stampFreshness(for: succeededTypes, scopes: [.shared])
                } else if let cacheService = appState.cacheService {
                    for type in succeededTypes {
                        cacheService.markCacheFresh(familyRecordName: family.id.recordName, type: type, scope: .shared)
                        cacheService.markCacheFresh(familyRecordName: family.id.recordName, type: type)
                    }
                }
            }
        } else if let concrete = syncCoordinator as? CKSyncEngineCoordinator {
            await concrete.delegateHandler.handleIncomingRecordsDirectly(
                snapshot.inboundRecords,
                databaseScope: .private,
                zoneID: zoneID
            )
            concrete.stampFreshness(for: succeededTypes, scopes: [.private])
        } else if let backgroundCache = appState.backgroundCacheActor {
            let parsed = snapshot.inboundRecords.map { ParsedRecord.parse(record: $0) }
            await backgroundCache.batchUpsertParsedRecords(parsed)
            if let cacheService = appState.cacheService {
                for type in succeededTypes {
                    cacheService.markCacheFresh(familyRecordName: family.id.recordName, type: type, scope: .private)
                    cacheService.markCacheFresh(familyRecordName: family.id.recordName, type: type)
                }
            }
        }
        // Track push age for debug overlay — completion of the snapshot
        // reconciliation pass represents a successful push-driven refresh.
        if let concrete = syncCoordinator as? CKSyncEngineCoordinator {
            concrete.notePushReceived()
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
