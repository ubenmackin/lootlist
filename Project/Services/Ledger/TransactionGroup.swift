//
//  TransactionGroup.swift
//  LootList
//
//  Created by Ben Mackin on 10/20/26.
//

import Foundation

/// Sendable snapshot of one ledger row for grouped history rendering.
/// WHY snapshot: live @Model rows never cross isolation, so groups carry value copies.
struct TransactionSplit: Sendable, Hashable, Identifiable, Equatable {
    let id: String
    let recordName: String
    let amount: Int64
    let entryDescription: String
    let date: Date
    let source: String
    let bucketKind: String?
    let fromBucket: String?
    let toBucket: String?
    let location: String?

    var sourceEnum: LedgerSource? {
        LedgerSource.decode(source)
    }

    var bucketKindEnum: BucketKind? {
        BucketKind.decode(bucketKind)
    }

    var fromBucketEnum: BucketKind? {
        BucketKind.decode(fromBucket)
    }

    var toBucketEnum: BucketKind? {
        BucketKind.decode(toBucket)
    }

    /// WHY per-filter legs: a single stored transfer credit reads as a debit from the source bucket.
    func displayAmount(for filter: BucketKind?) -> Int64 {
        guard let filter, sourceEnum == .transfer else { return amount }
        if fromBucketEnum == filter, bucketKindEnum != filter {
            return -amount
        }
        return amount
    }

    init(
        recordName: String,
        amount: Int64,
        entryDescription: String,
        date: Date,
        source: String,
        bucketKind: String? = nil,
        fromBucket: String? = nil,
        toBucket: String? = nil,
        location: String? = nil
    ) {
        id = recordName
        self.recordName = recordName
        self.amount = amount
        self.entryDescription = entryDescription
        self.date = date
        self.source = source
        self.bucketKind = bucketKind
        self.fromBucket = fromBucket
        self.toBucket = toBucket
        self.location = location
    }

    @MainActor init(from cache: LedgerEntryCache) {
        self.init(
            recordName: cache.recordName,
            amount: cache.amount,
            entryDescription: cache.entryDescription,
            date: cache.date,
            source: cache.source,
            bucketKind: cache.bucketKind,
            fromBucket: cache.fromBucket,
            toBucket: cache.toBucket,
            location: cache.location
        )
    }
}

extension TransactionSplit: LedgerEntryProtocol {}

/// One grouped history row with cumulative balances.
/// WHY per-filter running: All shows Total while each filter shows its own bucket via runningPennies(for:).
struct TransactionGroup: Sendable, Hashable, Identifiable, Equatable {
    let groupID: String
    let title: String
    let date: Date
    let totalPennies: Int64
    let runningTotalPennies: Int64
    let runningByBucket: [BucketKind: Int64]
    let splits: [TransactionSplit]
    let goalChildren: [TransactionSplit]
    let source: String

    init(
        groupID: String,
        title: String,
        date: Date,
        totalPennies: Int64,
        runningTotalPennies: Int64,
        runningByBucket: [BucketKind: Int64] = [:],
        splits: [TransactionSplit],
        goalChildren: [TransactionSplit],
        source: String
    ) {
        self.groupID = groupID
        self.title = title
        self.date = date
        self.totalPennies = totalPennies
        self.runningTotalPennies = runningTotalPennies
        self.runningByBucket = runningByBucket
        self.splits = splits
        self.goalChildren = goalChildren
        self.source = source
    }

    var id: String {
        groupID
    }

    /// WHY single owner: receipt anchor lives here so builder plus views never drift.
    var representativeSplit: TransactionSplit? {
        splits.min(by: { $0.recordName < $1.recordName })
    }

    /// WHY bucket running: All shows Total while each filter shows its own bucket running.
    func runningPennies(for filter: BucketKind?) -> Int64 {
        guard let filter else { return runningTotalPennies }
        return runningByBucket[filter] ?? 0
    }

    var sourceEnum: LedgerSource? {
        LedgerSource.decode(source)
    }
}
