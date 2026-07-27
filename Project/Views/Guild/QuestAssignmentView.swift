//
//  QuestAssignmentView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import SwiftUI

struct QuestAssignmentView: View {
    var mode: Mode = .fromTemplate
    @Bindable var viewModel: QuestManagerViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(QuestService.self) private var questService

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

    // --- Quick Create state ---
    @State private var quickName: String = ""
    @State private var quickDescription: String = ""
    @State private var quickGoldText: String = "1.00"
    @State private var quickRarity: QuestRarity = .common
    @State private var quickSchedule: QuestSchedule = .weeklyFlexible
    @State private var quickSpecificDays: Set<String> = []
    @State private var quickApproval: ApprovalMode = .autoApprove

    // --- Edit state ---
    @State private var editQuestName: String = ""
    @State private var editQuestDescription: String = ""
    @State private var editGoldText: String = ""
    @State private var editXpText: String = ""
    @State private var editSchedule: QuestSchedule = .weeklyFlexible
    @State private var editIsAllOrNothing: Bool = false
    @State private var editApproval: ApprovalMode = .autoApprove
    @State private var editAssignee: ProfileCache?
    @State private var allowLockedFieldsOverride: Bool = false
    @State private var editQuest: Quest?
    @State private var editHasLogs: Bool = false
    @State private var showOverrideAlert: Bool = false

    // --- Shared ---
    @State private var validationError: String?
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

                if let validationError {
                    Section {
                        Text(validationError)
                            .foregroundStyle(.red)
                            .font(.footnote)
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

    // --- Navigation title / button ---

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

    @ViewBuilder
    private var templateAssignmentSections: some View {
        Section("Template") {
            if viewModel.templates.filter(\.isActive).isEmpty {
                Text("No active templates. Create one in the Templates tab or use Quick Create.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Template", selection: $selectedTemplate) {
                    Text("Choose…").tag(nil as QuestTemplateCache?)
                    ForEach(viewModel.templates.filter(\.isActive)) { template in
                        Text(template.name).tag(template as QuestTemplateCache?)
                    }
                }
                .onChange(of: selectedTemplate) { _, newTemplate in
                    guard mode == .fromTemplate, !userEditedQuestName else { return }
                    editQuestName = newTemplate?.name ?? ""
                }
            }
        }

        // Edit-mode name override (fromTemplate path)
        Section {
            TextField("Quest Name", text: $editQuestName)
                .onChange(of: editQuestName) { _, _ in
                    userEditedQuestName = true
                }
            if let template = selectedTemplate {
                Text("From template: \(template.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Quest Name")
        } footer: {
            Text("Leave blank to use the template name.")
        }

        Section("Hero") {
            heroPicker
        }

        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Gold Override")
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(["1.00", "2.50", "5.00"], id: \.self) { preset in
                            PresetPill(
                                text: "$\(preset)",
                                isSelected: goldOverrideText == preset,
                                action: { goldOverrideText = preset }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                TextField(selectedTemplate?.goldReward.mapToText() ?? "",
                          text: $goldOverrideText)
                    .keyboardType(.decimalPad)
            }

            HStack {
                Text("XP Override")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField(selectedTemplate?.xpReward.mapToText() ?? "",
                          text: $xpOverrideText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }

            Picker("Approval", selection: $approvalOverride) {
                ForEach(ApprovalModeSelection.allCases) { sel in
                    Text(sel.rawValue).tag(sel)
                }
            }
        } header: {
            Text("Overrides (optional)")
        } footer: {
            Text("Leaving a field blank uses the template's default value.")
        }
    }

    // MARK: - Quick Create sections

    @ViewBuilder
    private var quickCreateSections: some View {
        Section("One-Off Quest Details") {
            TextField("Quest Name (e.g. Wash the Car)", text: $quickName)

            TextField("Description (optional)", text: $quickDescription, axis: .vertical)
                .lineLimit(2 ... 3)
        }

        Section("Hero") {
            heroPicker
        }

        Section("Rewards") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Gold Reward")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(["1.00", "2.50", "5.00"], id: \.self) { preset in
                            PresetPill(
                                text: "$\(preset)",
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
                    Text("Quest Rarity & XP")
                        .font(.subheadline)
                    Spacer()
                    Text("\(quickRarity.xpReward) XP")
                        .font(.subheadline.bold())
                        .foregroundStyle(quickRarity.color)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(QuestRarity.allCases) { rarity in
                            PresetPill(
                                text: "\(rarity.rawValue) (\(rarity.xpReward) XP)",
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
            Picker("Schedule", selection: $quickSchedule) {
                ForEach(QuestSchedule.allCases, id: \.self) { schedule in
                    Text(schedule.displayName).tag(schedule)
                }
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

            Picker("Approval", selection: $quickApproval) {
                ForEach(ApprovalMode.allCases, id: \.self) { approval in
                    Text(approval.displayName).tag(approval)
                }
            }
            .pickerStyle(.segmented)
        }
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
            HStack {
                Text("Gold Reward")
                    .foregroundStyle(editHasLogs ? .secondary : .primary)
                Spacer()
                TextField("0", text: $editGoldText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
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

            Picker("Approval", selection: $editApproval) {
                ForEach(ApprovalMode.allCases, id: \.self) { approval in
                    Text(approval.displayName).tag(approval)
                }
            }
            .pickerStyle(.segmented)
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
    private var heroPicker: some View {
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
            // Allow template selection to auto-sync name until user types
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
        let zoneID = questService.cloudKitReference.resolvedZoneID
        editQuest = quest.toQuest(zoneID: zoneID)
        // Edited quest name must not be clobbered by template selection
        userEditedQuestName = true
        editQuestName = quest.questName
        editQuestDescription = quest.descriptionText ?? ""
        editGoldText = String(format: "%.2f", quest.goldReward)
        editXpText = "\(quest.xpReward)"
        editSchedule = quest.scheduleTypeEnum
        editIsAllOrNothing = quest.isAllOrNothing
        editApproval = quest.approvalModeEnum

        // Resolve assignee from heroes list
        editAssignee = viewModel.heroes.first { $0.recordName == quest.assigneeRecordName }

        // Check if quest has logs (determines locked fields)
        Task {
            do {
                let logs = try await questService.fetchQuestLogs(forQuest: quest.toQuest(zoneID: zoneID))
                editHasLogs = !logs.isEmpty
            } catch {
                editHasLogs = false
            }
        }
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
            validationError = "Select a hero."
            return
        }
        guard let template = selectedTemplate else {
            validationError = "Select a template."
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

        let zoneID = questService.cloudKitReference.resolvedZoneID
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
                validationError = error.localizedDescription
            }
        }
    }

    private func submitQuickCreate() {
        guard let hero = selectedHero else {
            validationError = "Select a hero."
            return
        }
        let trimmedName = quickName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            validationError = "Quest name is required."
            return
        }
        guard let gold = Double(quickGoldText.trimmingCharacters(in: .whitespaces)), gold >= 0 else {
            validationError = "Gold reward must be a valid non-negative number."
            return
        }

        let xp = quickRarity.xpReward

        if quickSchedule == .specificDays, quickSpecificDays.isEmpty {
            validationError = "Select at least one day for specific-days schedule."
            return
        }

        let zoneID = questService.cloudKitReference.resolvedZoneID
        isSubmitting = true
        Task {
            do {
                try await viewModel.assignQuickQuest(
                    name: trimmedName,
                    description: quickDescription,
                    assignee: hero.toProfile(zoneID: zoneID),
                    goldReward: gold,
                    xpReward: xp,
                    scheduleType: quickSchedule,
                    specificDays: Array(quickSpecificDays),
                    approvalMode: quickApproval,
                    weekOf: weekOf
                )
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                validationError = error.localizedDescription
            }
        }
    }

    private func submitEdit() {
        guard let quest = editQuest else {
            validationError = "No quest to edit."
            return
        }
        guard let hero = editAssignee else {
            validationError = "Select a hero."
            return
        }

        guard let gold = Double(editGoldText.trimmingCharacters(in: .whitespaces)), gold >= 0 else {
            validationError = "Gold reward must be a valid non-negative number."
            return
        }
        guard let xp = Int(editXpText.trimmingCharacters(in: .whitespaces)), xp >= 0 else {
            validationError = "XP reward must be a valid non-negative number."
            return
        }

        let name = editQuestName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : editQuestName
        let description = editQuestDescription.trimmingCharacters(in: .whitespaces).isEmpty ? nil : editQuestDescription

        let zoneID = questService.cloudKitReference.resolvedZoneID
        isSubmitting = true
        Task {
            do {
                try await viewModel.updateQuest(
                    quest,
                    name: name,
                    descriptionText: description,
                    goldReward: gold,
                    xpReward: xp,
                    scheduleType: editSchedule,
                    isAllOrNothing: editIsAllOrNothing,
                    approvalMode: editApproval,
                    assignee: hero.toProfile(zoneID: zoneID),
                    allowLockedFieldsOverride: allowLockedFieldsOverride
                )
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                validationError = error.localizedDescription
            }
        }
    }

    private static func defaultWeekOf() -> Date {
        QuestService.mondayOfWeek(for: Date())
    }
}

private extension Double {
    func mapToText() -> String {
        String(format: "%.2f", self)
    }
}

private extension Int {
    func mapToText() -> String {
        String(self)
    }
}
