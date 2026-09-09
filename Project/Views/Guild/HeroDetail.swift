//
//  HeroDetail.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftUI

/// Compatibility alias retained for legacy HeroDetail callers; canonical detail lives in HeroDetailView.
struct HeroDetail: View {
    let hero: ProfileCache
    let familyRecordName: String?
    let spending: SpendingService

    var body: some View {
        HeroDetailView(hero: hero, familyRecordName: familyRecordName, spending: spending)
    }
}
