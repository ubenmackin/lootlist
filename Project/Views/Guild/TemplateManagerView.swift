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

    private let logger = Logger(category: "TemplateManager")

    let editing: QuestTemplateCache?
    var onCancel: (() -> Void)?

    @Environment(AppState.self) private var appState
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
                                ForEach(AppConstants.Rewards.rewardPresetsPennies, id: \.self) { preset in
                                    PresetPill(
                                        text: CurrencyFormatter.string(pennies: preset),
                                        isSelected: CurrencyFormatter.pennies(from: defaultGoldText) == preset,
                                        action: { defaultGoldText = CurrencyFormatter.editingString(preset) }
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        TextField(CurrencyFormatter.editingString(100), text: $defaultGoldText)
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
                                    ForEach(WeekMath.weekdayOrder.indices, id: \.self) { idx in
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
            .decimalPadDoneToolbar(isFocused: $isAmountFocused, amountText: $defaultGoldText)
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
        descriptionText = editing.templateDescription
        defaultGoldText = CurrencyFormatter.editingString(editing.goldReward)
        selectedRarity = editing.rarityEnum ?? .common
        schedule = editing.scheduleTypeEnum ?? .weeklyFlexible
        specificDays = Set(editing.specificDays ?? [])
        targetCount = editing.targetCount
        isAllOrNothing = editing.isAllOrNothing
        approvalMode = editing.approvalModeEnum ?? .autoApprove
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            toastManager.show(message: "Name is required.", type: .error)
            return
        }
        guard let gold = CurrencyFormatter.pennies(from: defaultGoldText),
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

        // WHY snapshot: @Model rows cannot cross isolation; Sendable structs ride the Task.
        let detailSnapshot = (name: trimmedName, description: descriptionText, gold: gold, xp: xp)
        let daysSnapshot: [String] = schedule.requiresSpecificDays ? Array(specificDays) : []
        let targetSnapshot = schedule == .weeklyFlexible ? max(1, targetCount) : 1
        let planSnapshot = (schedule: schedule, days: daysSnapshot, target: targetSnapshot, allOrNothing: effectiveAllOrNothing, approval: approvalMode)
        let zoneIDSnapshot = editing.map { appState.resolvedFamilyZoneID(fallbackRecord: $0) }
        let templateSnapshot = editing.flatMap { cache in
            zoneIDSnapshot.map { cache.toQuestTemplate(zoneID: $0) }
        }
        let onCancelSnapshot = onCancel
        isSaving = true
        // WHY MainActor view: isSaving mutates on the isolated task so Sendable captures stay race-free.
        Task { @MainActor [viewModel, detailSnapshot, planSnapshot, templateSnapshot, onCancelSnapshot, toastManager, dismiss, logger] in
            do {
                if var updated = templateSnapshot {
                    updated.name = detailSnapshot.name
                    updated.description = detailSnapshot.description
                    updated.defaultGold = detailSnapshot.gold
                    updated.xpReward = detailSnapshot.xp
                    updated.scheduleType = planSnapshot.schedule
                    updated.specificDays = planSnapshot.days
                    updated.targetCount = planSnapshot.target
                    updated.isAllOrNothing = planSnapshot.allOrNothing
                    updated.approvalMode = planSnapshot.approval
                    try await viewModel.updateTemplate(updated)
                } else {
                    try await viewModel.createTemplate(
                        name: detailSnapshot.name,
                        description: detailSnapshot.description,
                        defaultGold: detailSnapshot.gold,
                        xpReward: detailSnapshot.xp,
                        schedule: planSnapshot.schedule,
                        specificDays: planSnapshot.days,
                        targetCount: planSnapshot.target,
                        isAllOrNothing: planSnapshot.allOrNothing,
                        approvalMode: planSnapshot.approval
                    )
                }
                isSaving = false
                if let onCancelSnapshot {
                    onCancelSnapshot()
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
