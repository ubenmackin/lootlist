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
}
