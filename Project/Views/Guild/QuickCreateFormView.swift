//
//  QuickCreateFormView.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import SwiftUI

struct QuickCreateFormView: View {
    @Bindable var viewModel: QuestManagerViewModel

    @Binding var quickName: String
    @Binding var quickDescription: String
    @Binding var selectedHero: ProfileCache?
    @Binding var quickGoldText: String
    @Binding var quickRarity: QuestRarity
    @Binding var quickSchedule: QuestSchedule
    @Binding var quickSpecificDays: Set<String>
    @Binding var quickTargetCount: Int
    @Binding var quickIsAllOrNothing: Bool
    @Binding var quickApproval: ApprovalMode
    @Binding var postToBoard: Bool

    private static let weekdayCodes: [String] = AppConstants.weekdayCodes

    private var isMultiOccurrence: Bool {
        QuestSchedule.isMultiOccurrence(
            schedule: quickSchedule,
            targetCount: quickTargetCount,
            specificDaysCount: quickSpecificDays.count
        )
    }

    var body: some View {
        Section("One-Off Quest Details") {
            TextField("Quest Name (e.g. Wash the Car)", text: $quickName)

            TextField("Description (optional)", text: $quickDescription, axis: .vertical)
                .lineLimit(2 ... 3)

            Toggle("Post to Hero Board", isOn: $postToBoard)
            if postToBoard {
                Text("Any hero can claim this from the Hero Board first. Board quests have no due date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if !postToBoard {
            Section("Hero") {
                if viewModel.heroes.isEmpty {
                    Text("No heroes in the family.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Hero", selection: $selectedHero) {
                        Text("Choose…").tag(nil as ProfileCache?)
                        ForEach(viewModel.heroes) { hero in
                            Text(hero.displayName).tag(hero as ProfileCache?)
                        }
                    }
                }
            }
        }

        Section("Rewards") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reward")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(["1.00", "2.50", "5.00"], id: \.self) { preset in
                            PresetPill(
                                text: CurrencyFormatter.string(Double(preset) ?? 0),
                                isSelected: quickGoldText == preset,
                                action: { quickGoldText = preset }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                TextField("1.00", text: $quickGoldText)
                    .keyboardType(.decimalPad)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // Rarity tiers still size rewards internally; parents pick
                    // them by plain effort label while the XP figure stays
                    // hidden.
                    Text("Bonus Tier")
                        .font(.subheadline)
                    Spacer()
                    Text("\(quickRarity.xpReward) bonus")
                        .font(.subheadline.bold())
                        .foregroundStyle(quickRarity.color)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(QuestRarity.allCases) { rarity in
                            PresetPill(
                                text: "\(FlavorTextProvider.rewardTierName(for: rarity)) (\(rarity.xpReward) bonus)",
                                isSelected: quickRarity == rarity,
                                action: { quickRarity = rarity },
                                systemImage: rarity.iconSystemName,
                                color: rarity.color
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        Section("Schedule & Approval") {
            if !postToBoard {
                Picker("Schedule", selection: $quickSchedule) {
                    ForEach(QuestSchedule.allCases, id: \.self) { schedule in
                        Text(schedule.displayName).tag(schedule)
                    }
                }

                if quickSchedule == .weeklyFlexible {
                    Stepper("Required Times Per Week: \(quickTargetCount)", value: $quickTargetCount, in: 1 ... 7)
                }

                if quickSchedule == .specificDays {
                    VStack(alignment: .leading) {
                        Text("Repeat On")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(Self.weekdayCodes.indices), id: \.self) { idx in
                                    let code = Self.weekdayCodes[idx]
                                    PresetPill(
                                        text: AppConstants.weekdayAbbreviated[idx],
                                        isSelected: quickSpecificDays.contains(code),
                                        action: {
                                            if quickSpecificDays.contains(code) {
                                                quickSpecificDays.remove(code)
                                            } else {
                                                quickSpecificDays.insert(code)
                                            }
                                        }
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            Picker("Approval", selection: $quickApproval) {
                ForEach(ApprovalMode.allCases, id: \.self) { approval in
                    Text(approval.displayName).tag(approval)
                }
            }
            .pickerStyle(.segmented)
        }

        if isMultiOccurrence, !postToBoard {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("All-or-Nothing", isOn: $quickIsAllOrNothing)
                    Text(
                        "When enabled, the hero must complete all required days or times to earn the full reward. When disabled, rewards are earned incrementally per completion."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }
}
