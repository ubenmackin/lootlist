//
//  TreasuryViewModelTransferHardeningTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/7/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct TreasuryViewModelTransferHardeningTests {
    private struct TestAppState {
        let appState: AppState
        let zoneID: CKRecordZone.ID
        let profileName: String
    }

    private func makeAppState() -> TestAppState {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID),
            action: .none
        )
        let profile = Profile(
            displayName: "Test Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            payoutPolicy: .perQuest,
            payoutDay: nil,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        let appState = AppState()
        appState.currentProfile = profile
        appState.family = Family(
            name: "Test Family",
            createdBy: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            payoutPolicy: .perQuest,
            payoutDay: .sunday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        appState.familyZoneID = zoneID
        return TestAppState(appState: appState, zoneID: zoneID, profileName: "hero1")
    }

    private func makeTreasuryViewModel(_ state: TestAppState) throws -> TreasuryViewModel {
        let cloudKit = MockCloudKitService(zoneID: state.zoneID)
        let cache = try CacheService(inMemory: true)
        let treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache, appState: state.appState)
        let spending = SpendingService(cloudKit: cloudKit, cacheService: cache, appState: state.appState)
        return TreasuryViewModel(
            treasury: treasury, spending: spending, appState: state.appState
        )
    }

    private typealias TransferScaffold = TransferTestScaffold

    @Test
    func `ms-cents multi-transfer succeeds with distinct ids end to end`() async throws {
        let scaffold = try TransferScaffold()
        scaffold.seed("l-spend-in", amount: 20.00, source: "quest", bucketKind: BucketKind.spend.rawValue)

        let now = Date()
        let first = try await scaffold.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 4.00,
            profile: scaffold.hero, family: scaffold.family,
            at: now
        )
        let second = try await scaffold.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 6.00,
            profile: scaffold.hero, family: scaffold.family,
            at: now.addingTimeInterval(1)
        )

        // WHY distinct instants mint distinct ms-cents ids so unlimited moves never collide.
        #expect(first.id.recordName != second.id.recordName)
        #expect(scaffold.entries().count == 3)
        let balances = scaffold.buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")
        #expect(balances[.spend] == 10.00)
        #expect(balances[.shortTermSave] == 10.00)

        // WHY end-to-end: the same cached rows drive Treasury totals and the spending list.
        let state = makeAppState()
        let viewModel = try makeTreasuryViewModel(state)
        let ledgers = scaffold.entries()
        viewModel.rebuildLists(logs: [], ledgers: ledgers, quests: [], allowancePeriods: [], scope: .allTime, templates: [])
        #expect(viewModel.spendingLog.map(\.id).contains(first.id.recordName))
        #expect(viewModel.spendingLog.map(\.id).contains(second.id.recordName))
        #expect(viewModel.balance == 20.00)
        #expect(viewModel.spendBalance == 10.00)
    }

    @Test
    func `same-ms identical retry dedupes without forking`() async throws {
        let scaffold = try TransferScaffold()
        scaffold.seed("l-spend-in", amount: 20.00, source: "quest", bucketKind: BucketKind.spend.rawValue)

        let now = Date()
        let first = try await scaffold.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 4.00,
            profile: scaffold.hero, family: scaffold.family,
            at: now
        )
        let countAfterFirst = scaffold.entries().count

        // WHY replay-safe: same ms, cents, and pair mint the same base id so a retry converges.
        await #expect(throws: BucketServiceError.duplicateTodayTransfer) {
            _ = try await scaffold.buckets.transfer(
                from: .spend, to: .shortTermSave, amount: 4.00,
                profile: scaffold.hero, family: scaffold.family,
                at: now
            )
        }
        #expect(scaffold.entries().count == countAfterFirst)
        #expect(scaffold.cache.fetchLedgerEntry(recordName: first.id.recordName, family: "fam1") != nil)
        let balances = scaffold.buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")
        #expect(balances[.spend] == 16.00)
        #expect(balances[.shortTermSave] == 4.00)
    }

    @Test
    func `pending transfer survives refresh and stays queued for reconcile upload`() async throws {
        let scaffold = try TransferScaffold()
        scaffold.seed("l-spend-in", amount: 10.00, source: "quest", bucketKind: BucketKind.spend.rawValue)

        let entry = try await scaffold.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 4.00,
            profile: scaffold.hero, family: scaffold.family,
            at: Date()
        )
        let transferName = entry.id.recordName

        // WHY pending marker: local rows carry no server changeTag until the engine acks.
        guard let cached = scaffold.cache.fetchLedgerEntry(recordName: transferName, family: "fam1") else {
            Issue.record("Missing transfer row")
            return
        }
        #expect(cached.changeTag == nil || cached.changeTag == "")

        // WHY owner upsert-only: a snapshot missing the pending row must not prune it.
        let refreshed = scaffold.entries()
        #expect(refreshed.map(\.recordName).contains(transferName))
        let balances = scaffold.buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")
        #expect(balances[.spend] == 6.00)
        #expect(balances[.shortTermSave] == 4.00)

        let state = makeAppState()
        let viewModel = try makeTreasuryViewModel(state)
        viewModel.rebuildLists(logs: [], ledgers: refreshed, quests: [], allowancePeriods: [], scope: .allTime, templates: [])
        #expect(viewModel.spendingLog.map(\.id).contains(transferName))

        // WHY re-enqueue: the unsynced scan finds the pending transfer for the next sync pass.
        guard let container = scaffold.cache.container else {
            Issue.record("Missing container")
            return
        }
        let background = BackgroundCacheActor(container: container)
        let unsynced = await background.fetchUnsyncedRecordIDs(familyRecordName: "fam1", zoneID: scaffold.zoneID)
        #expect(unsynced.map(\.recordName).contains(transferName))
    }

    @Test
    func `transfer copy maps description and buckets to spending rows`() async throws {
        let scaffold = try TransferScaffold()
        scaffold.seed("l-spend-in", amount: 10.00, source: "quest", bucketKind: BucketKind.spend.rawValue)

        let entry = try await scaffold.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 4.00,
            profile: scaffold.hero, family: scaffold.family,
            at: Date()
        )

        // WHY single copy: one deterministic description carries both bucket names.
        #expect(entry.description == "Transfer from \(BucketKind.spend.displayName) to \(BucketKind.shortTermSave.displayName)")
        #expect(entry.source == LedgerSource.transfer.rawValue)
        #expect(entry.bucketKind == BucketKind.shortTermSave.rawValue)
        #expect(entry.fromBucket == BucketKind.spend.rawValue)
        #expect(entry.toBucket == BucketKind.shortTermSave.rawValue)

        let rows = LedgerRowFactory.spendingRows(from: scaffold.entries(), profileRecordName: "hero1", scope: .allTime, payoutDay: .sunday)
        guard let row = rows.first(where: { $0.id == entry.id.recordName }) else {
            Issue.record("Transfer row missing from spending rows")
            return
        }
        #expect(row.description == entry.description)
        #expect(row.amount == 4.00)
        #expect(row.source == LedgerSource.transfer.rawValue)
        #expect(row.rawCache?.fromBucket == BucketKind.spend.rawValue)
        #expect(row.rawCache?.toBucket == BucketKind.shortTermSave.rawValue)

        let state = makeAppState()
        let viewModel = try makeTreasuryViewModel(state)
        viewModel.rebuildLists(logs: [], ledgers: scaffold.entries(), quests: [], allowancePeriods: [], scope: .allTime, templates: [])
        #expect(viewModel.spendingLog.map(\.id).contains(entry.id.recordName))
    }
}
