//
//  TreasuryViewModelTransferCollisionTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/6/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct TreasuryViewModelTransferCollisionTests {
    private typealias TransferScaffold = TransferTestScaffold

    @Test
    func `multiple transfers on same day between same bucket pair succeed`() async throws {
        let scaffold = try TransferScaffold()
        scaffold.seed("l-spend-in", amount: 2000, source: "quest", bucketKind: BucketKind.spend.rawValue)

        let now = Date()
        let entry1 = try await scaffold.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 400,
            profile: scaffold.hero, family: scaffold.family,
            at: now
        )
        let entry2 = try await scaffold.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 600,
            profile: scaffold.hero, family: scaffold.family,
            at: now.addingTimeInterval(1)
        )

        #expect(entry1.id.recordName != entry2.id.recordName)
        #expect(scaffold.entries().count == 3) // 1 seed + 2 transfers
        let balances = scaffold.buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")
        #expect(balances[.spend] == 1000)
        #expect(balances[.shortTermSave] == 1000)

        // WHY distinct by construction: same instant but different cents (200c vs
        // 400c) mints a different base ID, so this never hits the collision branch.
        let entry3 = try await scaffold.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 200,
            profile: scaffold.hero, family: scaffold.family,
            at: now
        )
        #expect(entry3.id.recordName != entry1.id.recordName)
        #expect(scaffold.entries().count == 4)
        let finalBalances = scaffold.buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")
        #expect(finalBalances[.spend] == 800)
        #expect(finalBalances[.shortTermSave] == 1200)
    }

    @Test
    func `same millisecond same amount replay converges without a duplicate row`() async throws {
        let scaffold = try TransferScaffold()
        scaffold.seed("l-spend-in", amount: 2000, source: "quest", bucketKind: BucketKind.spend.rawValue)

        let now = Date()
        let entry1 = try await scaffold.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 400,
            profile: scaffold.hero, family: scaffold.family,
            at: now
        )
        let countAfterFirst = scaffold.entries().count
        let balancesAfterFirst = scaffold.buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")

        // WHY replay-safe: same instant, cents, and pair mint the same base ID,
        // so a retry must converge instead of forking a duplicate row.
        do {
            let replay = try await scaffold.buckets.transfer(
                from: .spend, to: .shortTermSave, amount: 400,
                profile: scaffold.hero, family: scaffold.family,
                at: now
            )
            // WHY idempotent return: the retry resolves to the original record.
            #expect(replay.id.recordName == entry1.id.recordName)
        } catch let error as BucketServiceError {
            // WHY deterministic duplicate: rejecting the identical retry with the
            // same error is also replay-safe while no row is added.
            #expect(error == .duplicateTodayTransfer)
        } catch {
            Issue.record("Unexpected error on identical replay: \(error)")
        }
        #expect(scaffold.entries().count == countAfterFirst)
        let replayBalances = scaffold.buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")
        #expect(replayBalances[.spend] == balancesAfterFirst[.spend])
        #expect(replayBalances[.shortTermSave] == balancesAfterFirst[.shortTermSave])
    }

    @Test
    func `divergent payload on the same base record extends deterministically`() async throws {
        let now = Date()
        let ms = Int(now.timeIntervalSince1970 * 1000)
        let cents = 400
        let baseRecordName = DeterministicRecordID.transfer(
            profileRecordName: "hero1",
            transferID: "\(ms)-\(cents)-\(BucketKind.spend.rawValue)-\(BucketKind.shortTermSave.rawValue)"
        )

        let scaffold = try TransferScaffold()
        scaffold.seed("l-spend-in", amount: 2000, source: "quest", bucketKind: BucketKind.spend.rawValue)
        // WHY forced collision: squat on the base name with a different amount so
        // the real transfer meets a divergent payload at the same record.
        scaffold.seed(
            baseRecordName,
            amount: 100,
            source: "transfer",
            bucketKind: BucketKind.shortTermSave.rawValue,
            fromBucket: BucketKind.spend.rawValue,
            toBucket: BucketKind.shortTermSave.rawValue
        )

        let extended = try await scaffold.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 400,
            profile: scaffold.hero, family: scaffold.family,
            at: now
        )
        // WHY deterministic extension: a divergent collision keeps the base as a
        // prefix with a payload-derived suffix instead of forking randomly.
        #expect(extended.id.recordName != baseRecordName)
        #expect(extended.id.recordName.hasPrefix(baseRecordName))
        #expect(scaffold.entries().count == 3)
        let balances = scaffold.buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")
        #expect(balances[.spend] == 1500)
        #expect(balances[.shortTermSave] == 500)

        // WHY cross-device convergence: the same divergent payload against the
        // same squatter must mint the same extended record on a fresh cache.
        let twin = try TransferScaffold()
        twin.seed("l-spend-in", amount: 2000, source: "quest", bucketKind: BucketKind.spend.rawValue)
        twin.seed(
            baseRecordName,
            amount: 100,
            source: "transfer",
            bucketKind: BucketKind.shortTermSave.rawValue,
            fromBucket: BucketKind.spend.rawValue,
            toBucket: BucketKind.shortTermSave.rawValue
        )
        let twinExtended = try await twin.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 400,
            profile: twin.hero, family: twin.family,
            at: now
        )
        #expect(twinExtended.id.recordName == extended.id.recordName)
    }
}
