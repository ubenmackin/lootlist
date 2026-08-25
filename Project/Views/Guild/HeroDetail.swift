//
//  HeroDetail.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftUI

/// Compatibility shim for the HeroDetail target path.
/// Canonical implementation is in `HeroDetailView.swift`; this wrapper preserves the expected file location while delegating to it.
struct HeroDetail: View {
    let hero: ProfileCache
    let familyRecordName: String?
    let spending: SpendingService

    var body: some View {
        HeroDetailView(hero: hero, familyRecordName: familyRecordName, spending: spending)
    }
}

// Entry link to KidsSavingsGoalsView is implemented in HeroDetailView.swift via NavigationLink(destination: KidsSavingsGoalsView(...)).
