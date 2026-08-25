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

            NavigationLink(destination: KidsSavingsGoalsView(familyRecordName: familyRecordName, focusedProfileRecordName: hero.recordName)) {
                HStack(spacing: 8) {
                    Image(systemName: "target")
                        .font(.subheadline.weight(.bold))
                    Text("Savings Goals")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.top, 10)
            .accessibilityLabel("View savings goals for \(hero.displayName)")

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
