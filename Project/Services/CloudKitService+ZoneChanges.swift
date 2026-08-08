//
//  CloudKitService+ZoneChanges.swift
//  LootList
//
//  Created by Ben Mackin on August 6, 2026.
//

import CloudKit
import Foundation
import os

extension CloudKitService {
    func fetchZoneChanges(
        in zoneID: CKRecordZone.ID? = nil,
        since token: CKServerChangeToken? = nil,
        using db: CKDatabase? = nil
    ) async throws -> ZoneChangesResult {
        if isTestingOrMocking {
            let parsed = mockRecords.values.map { Self.parseRecord($0) }
            return ZoneChangesResult(
                changedRecords: parsed,
                deletedRecordIDs: [],
                newToken: nil,
                moreComing: false
            )
        }

        let zone = zoneID ?? resolvedZoneID
        guard let targetDB = db ?? activeFamilyDatabase else {
            throw CloudKitServiceError.accountUnavailable
        }

        return try await retrying {
            var changedRecords: [ParsedRecord] = []
            var deletedRecordIDs: [(recordID: CKRecord.ID, recordType: String)] = []
            var newToken = token
            var moreComing = true

            while moreComing {
                let changes = try await targetDB.recordZoneChanges(inZoneWith: zone, since: newToken)

                for (_, result) in changes.modificationResultsByID {
                    if case let .success(modification) = result {
                        changedRecords.append(Self.parseRecord(modification.record))
                    }
                }
                for deletion in changes.deletions {
                    deletedRecordIDs.append((deletion.recordID, deletion.recordType))
                }

                newToken = changes.changeToken
                moreComing = changes.moreComing
            }

            return ZoneChangesResult(
                changedRecords: changedRecords,
                deletedRecordIDs: deletedRecordIDs,
                newToken: newToken,
                moreComing: moreComing
            )
        }
    }

    /// Decodes a raw `CKRecord` into a typed `ParsedRecord` enum case on the
    /// `@MainActor` side, so only Sendable domain structs cross into
    /// `BackgroundCacheActor`. Unknown record types or parse failures produce
    /// `.parseFailure` — the caller decides whether to log or skip.
    private static func parseRecord(_ record: CKRecord) -> ParsedRecord {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "CloudKitService")
        do {
            switch record.recordType {
            case Family.recordType:
                return try .family(Family(record: record))
            case Profile.recordType:
                return try .profile(Profile(record: record))
            case Quest.recordType:
                return try .quest(Quest(record: record))
            case QuestTemplate.recordType:
                return try .questTemplate(QuestTemplate(record: record))
            case QuestCompletion.recordType:
                return try .questCompletion(QuestCompletion(record: record))
            case LedgerEntry.recordType:
                return try .ledgerEntry(LedgerEntry(record: record))
            case AllowancePeriod.recordType:
                return try .allowancePeriod(AllowancePeriod(record: record))
            case Achievement.recordType:
                return try .achievement(Achievement(record: record))
            case ProfileAchievement.recordType:
                return try .profileAchievement(ProfileAchievement(record: record))
            case NotificationPreference.recordType:
                return try .notificationPreference(NotificationPreference(record: record))
            case "cloudkit.share", CKRecord.SystemType.share:
                logger.debug("Ignoring system record type '\(record.recordType, privacy: .public)' for \(record.recordID.recordName, privacy: .private)")
                return .ignoredSystemRecord(recordType: record.recordType, recordName: record.recordID.recordName)
            default:
                if record.recordType.hasPrefix("cloudkit.") {
                    logger.debug("Ignoring system record type '\(record.recordType, privacy: .public)' for \(record.recordID.recordName, privacy: .private)")
                    return .ignoredSystemRecord(recordType: record.recordType, recordName: record.recordID.recordName)
                }
                logger.warning("Unknown record type '\(record.recordType, privacy: .public)' for \(record.recordID.recordName, privacy: .private)")
                return .parseFailure(recordType: record.recordType, recordName: record.recordID.recordName)
            }
        } catch {
            logger.error("Failed to parse \(record.recordType, privacy: .public) record \(record.recordID.recordName, privacy: .private): \(error)")
            return .parseFailure(recordType: record.recordType, recordName: record.recordID.recordName)
        }
    }
}
