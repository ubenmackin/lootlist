//
//  RosterViewState.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import Foundation

/// Pure view state for the family roster: heroes and parents sorted for display.
/// Isolates roster sorting so the dashboard ViewModel stays focused on orchestration.
struct RosterViewState {
    let heroes: [ProfileCache]
    let parents: [ProfileCache]

    init(profiles: [ProfileCache]) {
        let active = profiles.filter(\.isActive)
        heroes = active
            .filter { $0.roleEnum == .hero }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        parents = active
            .filter { $0.roleEnum?.isParent == true }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Pure convenience matching the canonical cache-row tuple used across dashboard
    /// metrics. Only `profiles` participates; the remaining arrays are ignored so
    /// callers can thread the same tuple through all extracted types.
    static func make(
        profiles: [ProfileCache],
        quests _: [QuestCache],
        logs _: [QuestCompletionCache],
        ledgers _: [LedgerEntryCache],
        allowancePeriods _: [AllowancePeriodCache],
        profileAchievements _: [ProfileAchievementCache]
    ) -> RosterViewState {
        RosterViewState(profiles: profiles)
    }

    /// Short-form pure helper for roster-only tests.
    static func compute(from profiles: [ProfileCache]) -> RosterViewState {
        RosterViewState(profiles: profiles)
    }
}
