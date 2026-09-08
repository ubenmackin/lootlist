//
//  TransferSaveFailureDiagnosticsTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/07/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct TransferSaveFailureDiagnosticsTests {
    let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")

    private func transferRecord(recordName: String, amount: Double) -> CKRecord {
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let profileRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none)
        let entry = LedgerEntry(
            profile: profileRef,
            amount: amount,
            description: "Bucket move",
            date: Date(),
            source: LedgerSource.transfer.rawValue,
            bucketKind: BucketKind.shortTermSave.rawValue,
            fromBucket: BucketKind.spend.rawValue,
            toBucket: BucketKind.shortTermSave.rawValue,
            family: familyRef,
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
        return entry.toRecord()
    }

    @Test
    func `ledger revert message maps transfer to transfer copy`() {
        #expect(LedgerRevertMessage
            .revertedMessage(for: .ledgerEntry, sourceRawValue: LedgerSource.transfer.rawValue) == "Your transfer was reverted by newer server data. Pull to refresh.")
        #expect(LedgerRevertMessage.saveFailedMessage(for: .ledgerEntry, sourceRawValue: LedgerSource.transfer.rawValue) == "Your transfer couldn't be saved — pull to refresh.")
    }

    @Test
    func `resolver returns nil for transfer conflict and records diagnostics`() async throws {
        let cache = try CacheService(inMemory: true)
        let container = try #require(cache.container)
        let bgActor = BackgroundCacheActor(container: container)
        let resolver = CKSyncConflictResolver(cacheService: cache, backgroundCache: bgActor)

        let recordName = "transfer-diag-1"
        let clientRecord = transferRecord(recordName: recordName, amount: 5)
        let serverRecord = transferRecord(recordName: recordName, amount: 6)
        let ckError = CKError(
            .serverRecordChanged,
            userInfo: [
                CKRecordChangedErrorServerRecordKey: serverRecord,
                CKRecordChangedErrorClientRecordKey: clientRecord
            ]
        )

        let result = await resolver.resolveFailedSave(record: clientRecord, error: ckError, databaseScope: .private)
        #expect(result == nil)
        #if DEBUG
            let diagnostic = try #require(resolver.lastSaveFailureDiagnostic)
            #expect(diagnostic.contains("recordType=LedgerEntry"))
            #expect(diagnostic.contains(recordName))
            #expect(diagnostic.contains(LedgerSource.transfer.rawValue))
            #expect(diagnostic.contains("bucketKind="))
            #expect(diagnostic.contains("fromBucket="))
            #expect(diagnostic.contains("toBucket="))
            #expect(diagnostic.contains("zone="))
            #expect(diagnostic.contains("scope="))
            #expect(diagnostic.contains("serverRecordPresent="))
            #expect(diagnostic.contains("code="))
            #expect(diagnostic.contains("domain="))
        #endif
    }

    @Test
    func `delegate maps transfer record to transfer copy with diagnostics`() {
        let resolver = CKSyncConflictResolver()
        let delegate = CKSyncEngineDelegateHandler(conflictResolver: resolver)

        let record = transferRecord(recordName: "transfer-diag-2", amount: 5)
        #expect(delegate.discardedSaveMessage(for: record) == "Your transfer couldn't be saved — pull to refresh.")

        let ckError = CKError(.quotaExceeded)
        let diagnostic = delegate.discardedSaveDiagnostic(for: record, error: ckError, scope: .private)
        #expect(diagnostic.contains("recordType=LedgerEntry"))
        #expect(diagnostic.contains("transfer-diag-2"))
        #expect(diagnostic.contains(LedgerSource.transfer.rawValue))
        #expect(diagnostic.contains("bucketKind="))
        #expect(diagnostic.contains("zone="))
        #expect(diagnostic.contains("scope="))
        #expect(diagnostic.contains("serverRecordPresent="))
    }
}
