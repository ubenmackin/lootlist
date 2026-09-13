//
//  QuestAssignmentEditFormView.swift
//  LootList
//
//  Created by Ben Mackin on 9/13/26.
//

import SwiftUI

/// WHY split edit form: the combined Section chain stalls the Swift 6 type-checker.
struct QuestAssignmentEditFormView: View {
    @Binding var questName: String
    @Binding var questDescription: String
    @Binding var goldText: String
    @Binding var xpText: String
    @Binding var schedule: QuestSchedule
    @Binding var specificDays: Set<String>
    @Binding var targetCount: Int
    @Binding var isAllOrNothing: Bool
    @Binding var approval: ApprovalMode
    @Binding var assignee: ProfileCache?
    @Binding var propagateToTemplate: Bool
    @Binding var showOverrideAlert: Bool
    var isEditAmountFocused: FocusState<Bool>.Binding
    let heroes: [ProfileCache]
    let hasLogs: Bool
    let allowLockedOverride: Bool

    private var isMultiOccurrence: Bool {
        QuestSchedule.isMultiOccurrence(
            schedule: schedule,
            targetCount: targetCount,
            specificDaysCount: specificDays.count
        )
    }

    var body: some View {
        questDetailsSection
        heroSection
        rewardsSection
        scheduleSection
        templateSyncSection
        lockedNoticeSection
    }

    private var questDetailsSection: some View {
        Section("Quest Details") {
            TextField("Quest Name", text: $questName)

            TextField("Description (optional)", text: $questDescription, axis: .vertical)
                .lineLimit(2 ... 3)
        }
    }

    private var heroSection: some View {
        Section("Hero") {
            if hasLogs, !allowLockedOverride {
                HStack {
                    if let assignee {
                        Text(assignee.displayName)
                    } else {
                        Text("Unknown Hero")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Override") {
                        showOverrideAlert = true
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                }
            } else {
                heroPicker
            }
        }
    }

    private var rewardsSection: some View {
        Section {
            rewardAmountRow
            bonusRewardRow
            allOrNothingRow
        } header: {
            Text("Rewards")
        }
    }

    private var rewardAmountRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reward")
                .foregroundStyle(hasLogs ? .secondary : .primary)
            if !hasLogs {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AppConstants.Rewards.rewardPresetsPennies, id: \.self) { preset in
                            PresetPill(
                                text: CurrencyFormatter.string(pennies: preset),
                                isSelected: CurrencyFormatter.pennies(from: goldText) == preset,
                                action: { goldText = CurrencyFormatter.editingString(preset) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            TextField(CurrencyFormatter.editingString(100), text: $goldText)
                .keyboardType(.decimalPad)
                .focused(isEditAmountFocused)
                .disabled(hasLogs)
        }
    }

    @ViewBuilder
    private var bonusRewardRow: some View {
        if FeatureFlags.rpgImmersive {
            HStack {
                Text("Bonus Reward")
                    .foregroundStyle(hasLogs ? .secondary : .primary)
                Spacer()
                TextField("0", text: $xpText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .disabled(hasLogs)
            }
        }
    }

    @ViewBuilder
    private var allOrNothingRow: some View {
        if isMultiOccurrence {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("All-or-Nothing", isOn: $isAllOrNothing)
                    .disabled(hasLogs)
                Text(
                    "When enabled, the hero must complete all required days or times to earn the full reward. When disabled, rewards are earned incrementally per completion."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private var scheduleSection: some View {
        Section("Schedule & Approval") {
            Picker("Schedule", selection: $schedule) {
                ForEach(QuestSchedule.allCases, id: \.self) { schedule in
                    Text(schedule.displayName).tag(schedule)
                }
            }
            .disabled(hasLogs)

            if schedule == .weeklyFlexible {
                Stepper("Required Times Per Week: \(targetCount)", value: $targetCount, in: 1 ... 7)
                    .disabled(hasLogs)
            }

            specificDaysRow

            Picker("Approval", selection: $approval) {
                ForEach(ApprovalMode.allCases, id: \.self) { approval in
                    Text(approval.displayName).tag(approval)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var specificDaysRow: some View {
        if schedule == .specificDays {
            VStack(alignment: .leading) {
                Text("Repeat On")
                    .foregroundStyle(hasLogs ? .secondary : .primary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(WeekMath.weekdayOrder.indices), id: \.self) { idx in
                            let code = WeekMath.weekdayOrder[idx]
                            PresetPill(
                                text: AppConstants.weekdayAbbreviated[idx],
                                isSelected: specificDays.contains(code),
                                action: {
                                    if specificDays.contains(code) {
                                        specificDays.remove(code)
                                    } else {
                                        specificDays.insert(code)
                                    }
                                }
                            )
                            .disabled(hasLogs)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var templateSyncSection: some View {
        Section("Template Sync") {
            Toggle("Also update parent template", isOn: $propagateToTemplate)
                .help("Applies these schedule + day changes to the master template too, affecting future quests assigned from it.")
        }
    }

    @ViewBuilder
    private var lockedNoticeSection: some View {
        if hasLogs {
            Section {
                Text("🔒 Locked — Hero has started this quest. Name and description remain editable.")
                    .font(.caption)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
            }
        }
    }

    @ViewBuilder
    private var heroPicker: some View {
        if heroes.isEmpty {
            Text("No heroes in the family.")
                .foregroundStyle(.secondary)
        } else {
            Picker("Hero", selection: $assignee) {
                Text("Choose…").tag(nil as ProfileCache?)
                ForEach(heroes) { hero in
                    Text(hero.displayName).tag(hero as ProfileCache?)
                }
            }
        }
    }
}
