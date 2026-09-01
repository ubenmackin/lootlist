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

@MainActor
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

    private static func fetchAndBridge<T: CloudKitRecord>(_: T.Type, familyRecordName: String, zid: CKRecordZone.ID, db: CKDatabase?,
                                                          cloudKit: any CloudKitServiceProtocol) async throws -> SnapshotPartition
    {
        let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zid)
        let predicate: NSPredicate
        if T.recordType == Family.recordType {
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
        let service = cloudKitService
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
                        return try await Self.fetchSnapshot(
                            for: type,
                            cloudKit: service,
                            familyRecordName: familyRecordName,
                            zoneName: zoneName,
                            ownerName: ownerName,
                            isOwner: isOwnerCopy
                        )
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

        let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let targetScope: CKDatabase.Scope = isOwner ? .private : .shared
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
                databaseScope: targetScope,
                zoneID: zoneID
            )
            concrete.stampFreshness(for: succeededTypes, scopes: [targetScope])
        } else if let backgroundCache = appState.backgroundCacheActor {
            let parsed = snapshot.inboundRecords.map { ParsedRecord.parse(record: $0) }
            await backgroundCache.batchUpsertParsedRecords(parsed)
            if let cacheService = appState.cacheService {
                for type in succeededTypes {
                    cacheService.markCacheFresh(familyRecordName: family.id.recordName, type: type, scope: targetScope)
                    cacheService.markCacheFresh(familyRecordName: family.id.recordName, type: type)
                }
            }
        }
        // Track push age for debug overlay — completion of the snapshot
        // reconciliation pass represents a successful push-driven refresh.
        if let concrete = syncCoordinator as? CKSyncEngineCoordinator {
            concrete.notePushReceived()
        }

        await enqueueUnsyncedLocalRecords(family: family, zoneID: zoneID)
    }

    /// Client→server re-enqueue for locally-created rows that missed their
    /// initial CloudKit upload. Sanctioned exception to the ingest() contract:
    /// ARCHITECTURE §4 requires every server→cache write to ride
    /// `ingest()` (except the participant reconciliation door and pre-session
    /// FamilyService mirrors). This path never writes server payloads into
    /// cache — it synthesizes CKRecord.IDs for local→server enqueues only, so
    /// the single-ingest invariant for inbound records is preserved.
    ///
    /// Fetch runs off-MainActor on BackgroundCacheActor under
    /// SerialMutationQueue so the scan cannot interleave with reconciliation
    /// commits or payout transactions. Enqueue is linearized through the same
    /// queue and uses deterministic recordName ordering with a 50-item paging
    /// cap; overflow is truncated deterministically from the sorted tail and
    /// picked up on the next debounce window. Deterministic IDs (contrib-*,
    /// interest-*, match-*, transfer-*, import-*, plus stable quest/template
    /// recordNames) ensure CloudKit dedupes re-enqueued saves across devices.
    func enqueueUnsyncedLocalRecords(family: Family, zoneID: CKRecordZone.ID) async {
        let now = Date()
        let shouldProceed: Bool = state.withLock { flags in
            if let last = flags.lastUnsyncedEnqueueAt,
               now.timeIntervalSince(last) < Self.unsyncedEnqueueDebounceInterval
            {
                return false
            }
            flags.lastUnsyncedEnqueueAt = now
            return true
        }
        guard shouldProceed else {
            logger.debug("Unsynced re-enqueue throttled: within debounce window")
            return
        }

        guard let backgroundCache = appState?.backgroundCacheActor,
              let coordinator = syncCoordinator as? CKSyncEngineCoordinator
        else { return }

        let familyName = family.id.recordName
        var unsyncedIDs = await backgroundCache.fetchUnsyncedRecordIDs(familyRecordName: familyName, zoneID: zoneID)

        guard !unsyncedIDs.isEmpty else { return }

        // Deterministic ordering so the paging cap slices a stable prefix.
        unsyncedIDs.sort { $0.recordName < $1.recordName }

        let enqueueLimit = 50
        if unsyncedIDs.count > enqueueLimit {
            logger.warning(
                "Unsynced re-enqueue capped to \(enqueueLimit) (found \(unsyncedIDs.count)) — remainder will retry next window",
                family: familyName,
                zone: zoneID.zoneName
            )
            unsyncedIDs = Array(unsyncedIDs.prefix(enqueueLimit))
        }

        // Batch enqueue resolves the owner anchor once and enqueues atomically
        // on the correct database scope. SerialMutationQueue linearization is
        // provided by the preceding BackgroundCacheActor.fetchUnsyncedRecordIDs
        // scan (mutationQueue.write), so this batch cannot interleave with an
        // in-flight reconciliation commit or payout transaction.
        let idsToEnqueue = unsyncedIDs
        ActiveFamilyScopeGuard.batchEnqueueWithCorrectedOwner(
            coordinator,
            ids: idsToEnqueue,
            appState: appState,
            logger: logger,
            context: "AppLifecycleCoordinator.enqueueUnsyncedLocalRecords"
        )

        for id in idsToEnqueue {
            logger.log(
                level: .info,
                "Re-enqueuing unsynced local record '\(id.recordName, privacy: .private)' for CloudKit upload family=\(familyName, privacy: .private) zone=\(zoneID.zoneName, privacy: .private)"
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
