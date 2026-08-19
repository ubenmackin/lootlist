//
//  QuestAssignmentView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import os
import SwiftData
import SwiftUI

struct QuestAssignmentView: View {
    var mode: Mode = .fromTemplate
    @Bindable var viewModel: QuestManagerViewModel

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestAssignment")

    @Environment(ToastManager.self) private var toastManager
    @Environment(\.dismiss) private var dismiss
    @Environment(QuestService.self) private var questService
    @Environment(AppState.self) private var appState

    @Query private var cachedCompletions: [QuestCompletionCache]

    enum Mode: Equatable, Identifiable {
        case fromTemplate
        case quickCreate
        case edit(questID: CKRecord.ID)

        var id: String {
            switch self {
            case .fromTemplate: "fromTemplate"
            case .quickCreate: "quickCreate"
            case let .edit(id): "edit-\(id.recordName)"
            }
        }

        static func == (lhs: Mode, rhs: Mode) -> Bool {
            lhs.id == rhs.id
        }

        var isCreateMode: Bool {
            switch self {
            case .fromTemplate, .quickCreate: true
            case .edit: false
            }
        }
    }

    // --- From Template state ---
    @State private var selectedTemplate: QuestTemplateCache?
    @State private var selectedHero: ProfileCache?
    @State private var goldOverrideText: String = ""
    @State private var xpOverrideText: String = ""
    @State private var approvalOverride: ApprovalModeSelection = .useTemplate
    @State private var weekOf: Date = defaultWeekOf()

    @State private var quickName: String = ""
    @State private var quickDescription: String = ""
    @State private var quickGoldText: String = "1.00"
    @State private var quickRarity: QuestRarity = .common
    @State private var quickSchedule: QuestSchedule = .weeklyFlexible
    @State private var quickSpecificDays: Set<String> = []
    @State private var quickTargetCount: Int = 1
    @State private var quickApproval: ApprovalMode = .autoApprove

    @State private var editQuestName: String = ""
    @State private var editQuestDescription: String = ""
    @State private var editGoldText: String = ""
    @State private var editXpText: String = ""
    @State private var editSchedule: QuestSchedule = .weeklyFlexible
    @State private var editSpecificDays: Set<String> = []
    @State private var editTargetCount: Int = 1
    @State private var editIsAllOrNothing: Bool = false
    @State private var editApproval: ApprovalMode = .autoApprove
    @State private var editAssignee: ProfileCache?
    @State private var allowLockedFieldsOverride: Bool = false
    @State private var propagateToTemplate: Bool = false
    @State private var editQuest: Quest?
    @State private var editHasLogs: Bool = false
    @State private var showOverrideAlert: Bool = false

    // --- Shared ---
    @State private var isSubmitting: Bool = false
    @State private var userEditedQuestName: Bool = false

    enum CreationPickerOption: String, CaseIterable, Identifiable {
        case fromTemplate = "From Template"
        case quickCreate = "Quick Create (One-Off)"
        var id: String {
            rawValue
        }
    }

    @State private var creationPickerMode: CreationPickerOption = .fromTemplate

    enum ApprovalModeSelection: String, CaseIterable, Identifiable {
        case useTemplate = "Use Template Default"
        case autoApproveOverride = "Auto-Approve (override)"
        case parentVerifyOverride = "Parent Verifies (override)"
        var id: String {
            rawValue
        }
    }

    private static let weekdayCodes: [String] = AppConstants.weekdayCodes

    var body: some View {
        NavigationStack {
            Form {
                if mode.isCreateMode {
                    Section {
                        Picker("Creation Mode", selection: $creationPickerMode) {
                            ForEach(CreationPickerOption.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                switch displayMode {
                case .fromTemplate:
                    templateAssignmentSections
                case .quickCreate:
                    quickCreateSections
                case .edit:
                    editSections
                }

                if mode.isCreateMode {
                    Section("Week Of") {
                        DatePicker("Week Starting Monday",
                                   selection: $weekOf,
                                   displayedComponents: .date)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: submit) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(submitButtonLabel)
                        }
                    }
                    .disabled(isSubmitDisabled)
                }
            }
            .onAppear {
                performOnAppear()
            }
            .alert("Override Lock?", isPresented: $showOverrideAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Override", role: .destructive) {
                    allowLockedFieldsOverride = true
                }
            } message: {
                Text("Hero has already started this quest. Changing the assignee will move this quest. Continue?")
            }
            .toastOverlay()
        }
    }

    // MARK: - Display mode (what the form actually shows)

    private var displayMode: DisplayMode {
        switch mode {
        case .fromTemplate:
            creationPickerMode == .fromTemplate ? .fromTemplate : .quickCreate
        case .quickCreate:
            .quickCreate
        case .edit:
            .edit
        }
    }

    private enum DisplayMode {
        case fromTemplate, quickCreate, edit
    }

    private var navigationTitle: String {
        switch mode {
        case .fromTemplate, .quickCreate: "Assign Quest"
        case .edit: "Edit Quest"
        }
    }

    private var submitButtonLabel: String {
        switch mode {
        case .fromTemplate, .quickCreate: "Assign"
        case .edit: "Save"
        }
    }

    // MARK: - Template assignment sections

    private var templateAssignmentSections: some View {
        TemplateAssignmentFormView(
            viewModel: viewModel,
            isFromTemplateMode: mode == .fromTemplate,
            selectedTemplate: $selectedTemplate,
            editQuestName: $editQuestName,
            userEditedQuestName: $userEditedQuestName,
            selectedHero: $selectedHero,
            goldOverrideText: $goldOverrideText,
            xpOverrideText: $xpOverrideText,
            approvalOverride: $approvalOverride
        )
    }

    // MARK: - Quick Create sections

    private var quickCreateSections: some View {
        QuickCreateFormView(
            viewModel: viewModel,
            quickName: $quickName,
            quickDescription: $quickDescription,
            selectedHero: $selectedHero,
            quickGoldText: $quickGoldText,
            quickRarity: $quickRarity,
            quickSchedule: $quickSchedule,
            quickSpecificDays: $quickSpecificDays,
            quickTargetCount: $quickTargetCount,
            quickApproval: $quickApproval
        )
    }

    // MARK: - Edit sections

    @ViewBuilder
    private var editSections: some View {
        Section("Quest Details") {
            TextField("Quest Name", text: $editQuestName)

            TextField("Description (optional)", text: $editQuestDescription, axis: .vertical)
                .lineLimit(2 ... 3)
        }

        Section("Hero") {
            if editHasLogs, !allowLockedFieldsOverride {
                HStack {
                    if let assignee = editAssignee {
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
                    .foregroundStyle(.orange)
                }
            } else {
                heroPickerEdit
            }
        }

        Section("Rewards") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reward")
                    .foregroundStyle(editHasLogs ? .secondary : .primary)
                if !editHasLogs {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(["1.00", "2.50", "5.00"], id: \.self) { preset in
                                PresetPill(
                                    text: CurrencyFormatter.string(Double(preset) ?? 0),
                                    isSelected: editGoldText == preset,
                                    action: { editGoldText = preset }
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                TextField("1.00", text: $editGoldText)
                    .keyboardType(.decimalPad)
                    .disabled(editHasLogs)
            }

            HStack {
                Text("XP Reward")
                    .foregroundStyle(editHasLogs ? .secondary : .primary)
                Spacer()
                TextField("0", text: $editXpText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .disabled(editHasLogs)
            }

            Toggle("All-or-Nothing", isOn: $editIsAllOrNothing)
        }

        Section("Schedule & Approval") {
            Picker("Schedule", selection: $editSchedule) {
                ForEach(QuestSchedule.allCases, id: \.self) { schedule in
                    Text(schedule.displayName).tag(schedule)
                }
            }
            .disabled(editHasLogs)

            if editSchedule == .weeklyFlexible {
                Stepper("Required Times Per Week: \(editTargetCount)", value: $editTargetCount, in: 1 ... 7)
                    .disabled(editHasLogs)
            }

            if editSchedule == .specificDays {
                VStack(alignment: .leading) {
                    Text("Repeat On")
                        .foregroundStyle(editHasLogs ? .secondary : .primary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(Self.weekdayCodes.indices), id: \.self) { idx in
                                let code = Self.weekdayCodes[idx]
                                PresetPill(
                                    text: AppConstants.weekdayAbbreviated[idx],
                                    isSelected: editSpecificDays.contains(code),
                                    action: {
                                        if editSpecificDays.contains(code) {
                                            editSpecificDays.remove(code)
                                        } else {
                                            editSpecificDays.insert(code)
                                        }
                                    }
                                )
                                .disabled(editHasLogs)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Picker("Approval", selection: $editApproval) {
                ForEach(ApprovalMode.allCases, id: \.self) { approval in
                    Text(approval.displayName).tag(approval)
                }
            }
            .pickerStyle(.segmented)
        }

        Section("Template Sync") {
            Toggle("Also update parent template", isOn: $propagateToTemplate)
                .help("Applies these schedule + day changes to the master template too, affecting future quests assigned from it.")
        }

        if editHasLogs {
            Section {
                Text("🔒 Locked — Hero has started this quest. Name and description remain editable.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Hero pickers

    @ViewBuilder
    private var heroPickerEdit: some View {
        if viewModel.heroes.isEmpty {
            Text("No heroes in the family.")
                .foregroundStyle(.secondary)
        } else {
            Picker("Hero", selection: $editAssignee) {
                Text("Choose…").tag(nil as ProfileCache?)
                ForEach(viewModel.heroes) { hero in
                    Text(hero.displayName).tag(hero as ProfileCache?)
                }
            }
        }
    }

    // MARK: - Submit disabled

    private var isSubmitDisabled: Bool {
        if isSubmitting {
            return true
        }

        switch displayMode {
        case .fromTemplate:
            return selectedHero == nil || selectedTemplate == nil
        case .quickCreate:
            return selectedHero == nil || quickName.trimmingCharacters(in: .whitespaces).isEmpty
        case .edit:
            return editAssignee == nil
        }
    }

    // MARK: - On Appear

    private func performOnAppear() {
        switch mode {
        case .fromTemplate:
            if selectedTemplate == nil {
                selectedTemplate = viewModel.templates.first { $0.isActive }
            }
            if selectedHero == nil {
                selectedHero = viewModel.heroes.first
            }
            userEditedQuestName = false
            // Pre-fill template name
            editQuestName = selectedTemplate?.name ?? ""
        case .quickCreate:
            if selectedHero == nil {
                selectedHero = viewModel.heroes.first
            }
        case let .edit(questID):
            loadQuestForEditing(questID: questID)
        }
    }

    private func loadQuestForEditing(questID: CKRecord.ID) {
        guard let quest = viewModel.activeAssignments.first(where: { $0.recordName == questID.recordName }) else { return }
        let zoneID = questID.zoneID
        editQuest = quest.toQuest(zoneID: zoneID)
        // Edited quest name must not be clobbered by template selection
        userEditedQuestName = true
        editQuestName = quest.questName
        editQuestDescription = quest.descriptionText ?? ""
        editGoldText = String(quest.goldReward)
        editXpText = "\(quest.xpReward)"
        editSchedule = quest.scheduleTypeEnum ?? .weeklyFlexible
        editTargetCount = quest.targetCount
        editIsAllOrNothing = quest.isAllOrNothing
        editApproval = quest.approvalModeEnum ?? .autoApprove

        if let template = viewModel.templates.first(where: { $0.recordName == quest.templateRecordName }) {
            editSpecificDays = Set(template.specificDays ?? [])
        } else {
            editSpecificDays = []
        }

        // Resolve assignee from heroes list
        editAssignee = viewModel.heroes.first { $0.recordName == quest.assigneeRecordName }

        // Check if quest has logs (determines locked fields) synchronously from cache
        editHasLogs = cachedCompletions.contains { $0.questRecordName == quest.recordName }
    }

    // MARK: - Submit

    private func submit() {
        switch displayMode {
        case .fromTemplate:
            submitFromTemplate()
        case .quickCreate:
            submitQuickCreate()
        case .edit:
            submitEdit()
        }
    }

    private func submitFromTemplate() {
        guard let hero = selectedHero else {
            toastManager.show(message: "Select a hero.", type: .error)
            return
        }
        guard let template = selectedTemplate else {
            toastManager.show(message: "Select a template.", type: .error)
            return
        }

        let gold: Double? = Double(goldOverrideText.trimmingCharacters(in: .whitespaces))
        let xp: Int? = Int(xpOverrideText.trimmingCharacters(in: .whitespaces))
        let approval: ApprovalMode? = switch approvalOverride {
        case .useTemplate: nil
        case .autoApproveOverride: .autoApprove
        case .parentVerifyOverride: .parentVerify
        }

        // Template name override: use editQuestName if non-empty, else nil (falls back to template.name)
        let nameOverride = editQuestName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : editQuestName

        let zoneID = appState.familyZoneID ?? appState.family?.id.zoneID ?? template.validatedZoneID(requestedZoneID: CKRecordZone.default().zoneID)
        isSubmitting = true
        Task {
            do {
                try await viewModel.assignQuest(
                    template: template.toQuestTemplate(zoneID: zoneID),
                    assignee: hero.toProfile(zoneID: zoneID),
                    goldOverride: gold,
                    xpOverride: xp,
                    approvalOverride: approval,
                    nameOverride: nameOverride,
                    weekOf: weekOf
                )
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                logger.error("Failed to assign quest from template: \(error, privacy: .private)")
                toastManager.show(message: "Could not assign the quest. Please try again.", type: .error)
            }
        }
    }

    private func submitQuickCreate() {
        guard let hero = selectedHero else {
            toastManager.show(message: "Select a hero.", type: .error)
            return
        }
        let trimmedName = quickName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            toastManager.show(message: "Quest name is required.", type: .error)
            return
        }
        guard let gold = Double(quickGoldText.trimmingCharacters(in: .whitespaces)), gold >= 0 else {
            toastManager.show(message: "Reward must be a valid non-negative number.", type: .error)
            return
        }

        let xp = quickRarity.xpReward

        if quickSchedule == .specificDays, quickSpecificDays.isEmpty {
            toastManager.show(message: "Select at least one day for specific-days schedule.", type: .error)
            return
        }

        let zoneID = appState.familyZoneID ?? appState.family?.id.zoneID ?? hero.validatedZoneID(requestedZoneID: CKRecordZone.default().zoneID)
        isSubmitting = true
        let input = QuestManagerViewModel.QuickQuestInput(
            name: trimmedName,
            description: quickDescription,
            assignee: hero.toProfile(zoneID: zoneID),
            goldReward: gold,
            xpReward: xp,
            scheduleType: quickSchedule,
            specificDays: Array(quickSpecificDays),
            targetCount: quickSchedule == .weeklyFlexible ? max(1, quickTargetCount) : 1,
            approvalMode: quickApproval,
            weekOf: weekOf
        )
        Task {
            do {
                try await viewModel.assignQuickQuest(input)
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                logger.error("Failed to create quest: \(error, privacy: .private)")
                toastManager.show(message: "Could not create the quest. Please try again.", type: .error)
            }
        }
    }

    private func submitEdit() {
        guard let quest = editQuest else {
            toastManager.show(message: "No quest to edit.", type: .error)
            return
        }
        guard let hero = editAssignee else {
            toastManager.show(message: "Select a hero.", type: .error)
            return
        }

        guard let gold = Double(editGoldText.trimmingCharacters(in: .whitespaces)), gold >= 0 else {
            toastManager.show(message: "Reward must be a valid non-negative number.", type: .error)
            return
        }
        guard let xp = Int(editXpText.trimmingCharacters(in: .whitespaces)), xp >= 0 else {
            toastManager.show(message: "XP reward must be a valid non-negative number.", type: .error)
            return
        }

        if editSchedule == .specificDays, editSpecificDays.isEmpty {
            toastManager.show(message: "Select at least one day for specific-days schedule.", type: .error)
            return
        }

        let name = editQuestName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : editQuestName
        let description = editQuestDescription.trimmingCharacters(in: .whitespaces).isEmpty ? nil : editQuestDescription

        let zoneID = quest.id.zoneID
        isSubmitting = true
        let input = QuestManagerViewModel.UpdateQuestInput(
            name: name,
            descriptionText: description,
            goldReward: gold,
            xpReward: xp,
            scheduleType: editSchedule,
            specificDays: Array(editSpecificDays),
            targetCount: editSchedule == .weeklyFlexible ? max(1, editTargetCount) : 1,
            isAllOrNothing: editIsAllOrNothing,
            approvalMode: editApproval,
            assignee: hero.toProfile(zoneID: zoneID),
            allowLockedFieldsOverride: allowLockedFieldsOverride,
            propagateToTemplate: propagateToTemplate
        )
        Task {
            do {
                try await viewModel.updateQuest(quest, input: input)
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                logger.error("Failed to update quest: \(error, privacy: .private)")
                toastManager.show(message: "Could not update the quest. Please try again.", type: .error)
            }
        }
    }

    private static func defaultWeekOf() -> Date {
        QuestService.mondayOfWeek(for: Date())
    }
}
