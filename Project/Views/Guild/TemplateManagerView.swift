//
//  TemplateManagerView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import os
import SwiftUI

struct TemplateManagerView: View {
    @Bindable var viewModel: QuestManagerViewModel

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "TemplateManager")

    let editing: QuestTemplate?
    var onCancel: (() -> Void)?

    @Environment(ToastManager.self) private var toastManager
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var descriptionText: String = ""
    @State private var defaultGoldText: String = ""
    @State private var selectedRarity: QuestRarity = .common
    @State private var schedule: QuestSchedule = .weeklyFlexible
    @State private var specificDays: Set<String> = []
    @State private var targetCount: Int = 1
    @State private var isAllOrNothing: Bool = false
    @State private var approvalMode: ApprovalMode = .autoApprove
    @State private var isSaving: Bool = false
    @FocusState private var isAmountFocused: Bool

    private static let weekdayCodes: [String] = AppConstants.weekdayCodes

    var body: some View {
        NavigationStack {
            Form {
                Section("Template Details") {
                    TextField("Template Name", text: $name)
                    TextField("Description", text: $descriptionText, axis: .vertical)
                        .lineLimit(2 ... 4)
                }

                Section("Default Rewards") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Default Reward")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(["1.00", "2.50", "5.00"], id: \.self) { preset in
                                    PresetPill(
                                        text: CurrencyFormatter.presetString(preset),
                                        isSelected: defaultGoldText == preset,
                                        action: { defaultGoldText = preset }
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        TextField("1.00", text: $defaultGoldText)
                            .keyboardType(.decimalPad)
                            .focused($isAmountFocused)
                    }

                    // Legacy RPG chrome hidden when FeatureFlags.rpgImmersive is false.
                    if FeatureFlags.rpgImmersive {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Bonus Tier")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(selectedRarity.xpReward) bonus")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(selectedRarity.color)
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(QuestRarity.allCases) { rarity in
                                        PresetPill(
                                            text: "\(FlavorTextProvider.rewardTierName(for: rarity)) (\(rarity.xpReward) bonus)",
                                            isSelected: selectedRarity == rarity,
                                            action: { selectedRarity = rarity },
                                            systemImage: rarity.iconSystemName,
                                            color: rarity.color
                                        )
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                Section("Schedule") {
                    Picker("Type", selection: $schedule) {
                        ForEach(QuestSchedule.allCases, id: \.self) { questSchedule in
                            Text(questSchedule.displayName).tag(questSchedule)
                        }
                    }
                    if schedule == .weeklyFlexible {
                        Stepper("Required Times Per Week: \(targetCount)", value: $targetCount, in: 1 ... 7)
                    }
                    if schedule == .specificDays {
                        VStack(alignment: .leading) {
                            Text("Repeat On")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Self.weekdayCodes.indices, id: \.self) { idx in
                                        let code = Self.weekdayCodes[idx]
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
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                if isMultiOccurrence {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("All-or-Nothing", isOn: $isAllOrNothing)
                            Text(
                                "When enabled, the hero must complete all required days or times to earn the full reward. When disabled, rewards are earned incrementally per completion."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("Approval") {
                    Picker("Mode", selection: $approvalMode) {
                        ForEach(ApprovalMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle(editing == nil ? "New Template" : "Edit Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        if let onCancel {
                            onCancel()
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if onCancel != nil {
                            Button {
                                onCancel?()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("Close inspector")
                        }
                        Button(action: save) {
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("Save")
                            }
                        }
                        .disabled(isSaving)
                    }
                }
            }
            .decimalPadDoneToolbar(isFocused: $isAmountFocused)
            .onAppear(perform: hydrateFromEditing)
            .toastOverlay()
        }
    }

    private var isMultiOccurrence: Bool {
        QuestSchedule.isMultiOccurrence(
            schedule: schedule,
            targetCount: targetCount,
            specificDaysCount: specificDays.count
        )
    }

    private func hydrateFromEditing() {
        guard let editing else { return }
        name = editing.name
        descriptionText = editing.description
        defaultGoldText = CurrencyFormatter.editingString(editing.defaultGold)
        selectedRarity = editing.rarity
        schedule = editing.scheduleType
        specificDays = Set(editing.specificDays)
        targetCount = editing.targetCount
        isAllOrNothing = editing.isAllOrNothing
        approvalMode = editing.approvalMode
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            toastManager.show(message: "Name is required.", type: .error)
            return
        }
        guard let gold = Double(defaultGoldText.trimmingCharacters(in: .whitespaces)),
              gold >= 0
        else {
            toastManager.show(message: "Reward must be a non-negative number.", type: .error)
            return
        }
        // Legacy RPG chrome hidden when FeatureFlags.rpgImmersive is false.
        let xp = FeatureFlags.rpgImmersive ? selectedRarity.xpReward : AppConstants.Rarity.commonXP
        if schedule == .specificDays, specificDays.isEmpty {
            toastManager.show(message: "Pick at least one day for Specific-Days schedule.", type: .error)
            return
        }

        let effectiveAllOrNothing = isMultiOccurrence ? isAllOrNothing : false

        isSaving = true
        Task {
            do {
                if let editing {
                    var updated = editing
                    updated.name = trimmedName
                    updated.description = descriptionText
                    updated.defaultGold = gold
                    updated.xpReward = xp
                    updated.scheduleType = schedule
                    updated.specificDays = schedule.requiresSpecificDays
                        ? Array(specificDays)
                        : []
                    updated.targetCount = schedule == .weeklyFlexible ? max(1, targetCount) : 1
                    updated.isAllOrNothing = effectiveAllOrNothing
                    updated.approvalMode = approvalMode
                    try await viewModel.updateTemplate(updated)
                } else {
                    try await viewModel.createTemplate(
                        name: trimmedName,
                        description: descriptionText,
                        defaultGold: gold,
                        xpReward: xp,
                        schedule: schedule,
                        specificDays: schedule.requiresSpecificDays
                            ? Array(specificDays)
                            : [],
                        targetCount: schedule == .weeklyFlexible ? max(1, targetCount) : 1,
                        isAllOrNothing: effectiveAllOrNothing,
                        approvalMode: approvalMode
                    )
                }
                isSaving = false
                if let onCancel {
                    onCancel()
                } else {
                    dismiss()
                }
            } catch {
                isSaving = false
                logger.error("Failed to save template: \(error, privacy: .private)")
                toastManager.show(message: "Could not save the template. Please try again.", type: .error)
            }
        }
    }
}
