//
//  HeroDetailView.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import SwiftUI

struct HeroDetailView: View {
    let hero: ProfileCache
    let familyRecordName: String?
    let spending: SpendingService

    @State private var selectedSegment: HeroDetailSegment = .quests

    enum HeroDetailSegment: String, CaseIterable {
        case quests = "Quests"
        case treasury = "Treasury"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedSegment) {
                ForEach(HeroDetailSegment.allCases, id: \.self) { segment in
                    Text(segment.rawValue).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .background(Color(.systemGroupedBackground))

            switch selectedSegment {
            case .quests:
                QuestLogView(initialHero: hero, familyRecordName: familyRecordName)
            case .treasury:
                HeroLedgerView(hero: hero, familyRecordName: familyRecordName, spending: spending)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(hero.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
