//
//  GoalWiring.swift
//  LootList
//
//  Created by Ben Mackin on 10/20/26.
//

import Foundation

/// Single wishlist destination for ledger goal taps.
struct GoalWishlistRoute: Hashable, Identifiable, Sendable {
    let profileRecordName: String
    let highlightGoalRecordName: String
    var id: String {
        profileRecordName + "-" + highlightGoalRecordName
    }
}

/// Single owner of ledger-to-wishlist goal wiring.
@MainActor
enum GoalWiring {
    /// WHY cache truth: GoalService owns contribution identity, cache name is display truth.
    static func goalNames(from cachedGoals: [GoalCache]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: cachedGoals.map { ($0.recordName, $0.name) })
    }

    /// WHY fail-closed: archived goals stay non-tappable.
    static func archivedIDs(from cachedGoals: [GoalCache]) -> Set<String> {
        Set(cachedGoals.filter(\.isArchived).map(\.recordName))
    }

    /// WHY fail-closed: missing plus archived plus empty profile never navigate to the wishlist.
    static func wishlistRoute(
        for goalRecordName: String,
        profileRecordName: String,
        goalNames: [String: String],
        archivedGoalIDs: Set<String>
    ) -> GoalWishlistRoute? {
        guard let name = goalNames[goalRecordName],
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !archivedGoalIDs.contains(goalRecordName),
              !profileRecordName.isEmpty
        else { return nil }
        return GoalWishlistRoute(
            profileRecordName: profileRecordName,
            highlightGoalRecordName: goalRecordName
        )
    }
}
