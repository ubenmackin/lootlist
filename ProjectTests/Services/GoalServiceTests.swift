//
//  GoalServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/30/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct GoalServiceTests {
    private func makeGoal(recordName: String,
                          profileRecordName: String = "hero1",
                          bucketKind: BucketKind = .shortTermSave,
                          targetPennies: Int64,
                          hoursAgo: Int = 0,
                          completedAt: Date? = nil,
                          isArchived: Bool = false) -> GoalCache
    {
        let createdAt = Date().addingTimeInterval(TimeInterval(-hoursAgo * 3600))
        return GoalCache(
            recordName: recordName,
            profileRecordName: profileRecordName,
            familyRecordName: "fam1",
            bucketKind: bucketKind.rawValue,
            name: recordName,
            targetAmountPennies: targetPennies,
            createdAt: createdAt,
            completedAt: completedAt,
            isArchived: isArchived
        )
    }

    @Test
    func `allocate ignores archived completed goal`() {
        let archivedCompleted = makeGoal(
            recordName: "g1",
            targetPennies: 500,
            hoursAgo: 10,
            completedAt: Date(),
            isArchived: true
        )
        let active = makeGoal(
            recordName: "g2",
            targetPennies: 500,
            hoursAgo: 5
        )
        let result = GoalService.allocate(amountPennies: 500, goals: [archivedCompleted, active])
        #expect(result.count == 1)
        #expect(result[0].goalRecordName == "g2")
        #expect(result[0].allocatedPennies == 500)
    }
}
