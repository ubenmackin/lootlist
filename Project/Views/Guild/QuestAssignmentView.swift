//
//  QuestAssignmentView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import os
import SwiftData
import SwiftUI

struct QuestAssignmentView: View {
    var mode: Mode
    @Bindable var viewModel: QuestManagerViewModel

    private let logger = Logger(category: "QuestAssignment")

    @Environment(ToastManager.self) private var toastManager
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedTemplates: [QuestTemplateCache]
    @Query private var cachedAssignments: [QuestCache]
    @Query private var cachedProfiles: [ProfileCache]

    private let familyRecordName: String?
    var onCancel: (() -> Void)?

    init(mode: Mode = .fromTemplate, viewModel: QuestManagerViewModel, familyRecordName: String? = nil, onCancel: (() -> Void)? = nil) {
        self.mode = mode
        self.viewModel = viewModel
        self.familyRecordName = familyRecordName
        self.onCancel = onCancel

        let targetFamily = familyRecordName ?? ""
        if targetFamily.isEmpty {
            // WHY fail-closed: empty scope must return zero rows via indexed predicate, never an unscoped scan.
            _cachedCompletions = Query(
                filter: QuestCompletionCache.emptyPredicate(),
                sort: [SortDescriptor(\QuestCompletionCache.completedDate, order: .reverse), SortDescriptor(\QuestCompletionCache.recordName)]
            )
        } else {
            let completionFilter = QuestCompletionCache.familyPredicate(familyRecordName: targetFamily)
            // WHY stable sorts: secondary recordName keeps ordering deterministic across CloudKit merge reorders.
            _cachedCompletions = Query(
                filter: completionFilter,
                sort: [SortDescriptor(\QuestCompletionCache.completedDate, order: .reverse), SortDescriptor(\QuestCompletionCache.recordName)]
            )
        }
        if targetFamily.isEmpty {
            // WHY fail-closed: empty scope must return zero rows via indexed predicate, never an unscoped scan.
            _cachedTemplates = Query(
                filter: QuestTemplateCache.emptyPredicate(),
                sort: [SortDescriptor(\QuestTemplateCache.name), SortDescriptor(\QuestTemplateCache.recordName)]
            )
        } else {
            _cachedTemplates = Query(
                filter: QuestTemplateCache.familyPredicate(familyRecordName: targetFamily),
                sort: [SortDescriptor(\QuestTemplateCache.name), SortDescriptor(\QuestTemplateCache.recordName)]
            )
        }
        _cachedAssignments = Query(
            filter: QuestCache.familyPredicate(familyRecordName: targetFamily),
            sort: [SortDescriptor(\QuestCache.weekOf, order: .reverse), SortDescriptor(\QuestCache.recordName)]
        )
        _cachedProfiles = Query(
            filter: ProfileCache.familyPredicate(familyRecordName: targetFamily),
            sort: [SortDescriptor(\ProfileCache.displayName), SortDescriptor(\ProfileCache.recordName)]
        )
    }

    enum Mode: Equatable, Identifiable {
        case fromTemplate
        case quickCreate
        case edit(questRecordName: String)

        var id: String {
            switch self {
            case .fromTemplate: "fromTemplate"
            case .quickCreate: "quickCreate"
            case let .edit(recordName): "edit-\(recordName)"
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
    @State private var templateIsAllOrNothing: Bool = false
    @State private var weekOf: Date = defaultWeekOf()

    @State private var quickName: String = ""
    @State private var quickDescription: String = ""
    @State private var quickGoldText: String = CurrencyFormatter.editingString(100)
    @State private var quickRarity: QuestRarity = .common
    @State private var quickSchedule: QuestSchedule = .weeklyFlexible
    @State private var quickSpecificDays: Set<String> = []
    @State private var quickTargetCount: Int = 1
    @State private var quickIsAllOrNothing: Bool = false
    @State private var quickApproval: ApprovalMode = .autoApprove
    @State private var quickPostToBoard: Bool = false

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
    @State private var editQuestCache: QuestCache?
    @State private var editHasLogs: Bool = false
    @State private var showOverrideAlert: Bool = false

    // --- Shared ---
    @State private var isSubmitting: Bool = false
    @State private var userEditedQuestName: Bool = false
    @FocusState private var isEditAmountFocused: Bool

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

    var body: some View {
        NavigationStack {
            assignmentForm
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { assignmentToolbar }
                .modifier(assignmentLifecycle)
                .modifier(assignmentDialogs)
        }
        // WHY: view identity tracks family so @Query predicate (init-captured) is recreated on scope switch.
        .id(familyRecordName ?? "")
    }

    private var assignmentForm: some View {
        Form {
            creationModeSection
            displayModeSections
            weekOfSection
        }
    }

    @ViewBuilder
    private var creationModeSection: some View {
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
    }

    /// WHY separate switch: the Form-level if/switch/if combo stalls the Swift 6 type-checker.
    @ViewBuilder
    private var displayModeSections: some View {
        switch displayMode {
        case .fromTemplate:
            templateAssignmentSections
        case .quickCreate:
            quickCreateSections
        case .edit:
            editSections
        }
    }

    @ViewBuilder
    private var weekOfSection: some View {
        if mode.isCreateMode, !(displayMode == .quickCreate && quickPostToBoard) {
            Section("Week Of") {
                DatePicker("Week Starting Monday",
                           selection: $weekOf,
                           displayedComponents: .date)
            }
        }
    }

    // MARK: - Toolbar (extracted to keep body shallow for the Swift 6 type-checker)

    @ToolbarContentBuilder
    private var assignmentToolbar: some ToolbarContent {
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
            trailingToolbarButtons
        }
    }

    private var trailingToolbarButtons: some View {
        HStack(spacing: 12) {
            if onCancel != nil {
                Button {
                    onCancel?()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close inspector")
            }
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

    private var assignmentLifecycle: some ViewModifier {
        AssignmentLifecycleModifier(
            cachedCompletions: cachedCompletions,
            cachedTemplates: cachedTemplates,
            cachedProfiles: cachedProfiles,
            cachedAssignments: cachedAssignments,
            onAppear: { performOnAppear() },
            onCompletionsChanged: { refreshEditLock() },
            onCacheChanged: { syncLiveSelections() }
        )
    }

    private var assignmentDialogs: some ViewModifier {
        AssignmentDialogsModifier(
            showOverrideAlert: $showOverrideAlert,
            isEditAmountFocused: $isEditAmountFocused,
            editAmountText: $editGoldText,
            onOverride: { allowLockedFieldsOverride = true }
        )
    }

    // MARK: - Live cache slices (what the form actually shows)

    private var liveTemplates: [QuestTemplateCache] {
        // WHY live-first: @Query rows own the hot path; ViewModel arrays bridge pre-hydration gaps.
        cachedTemplates.isEmpty ? viewModel.templates : cachedTemplates
    }

    private var liveHeroes: [ProfileCache] {
        // WHY live-first: @Query rows own the hot path; ViewModel arrays bridge pre-hydration gaps.
        let heroes = cachedProfiles.filter { $0.role == UserRole.hero.rawValue }
        return heroes.isEmpty ? viewModel.heroes : heroes
    }

    private var liveAssignments: [QuestCache] {
        // WHY live-first: @Query rows own the hot path; ViewModel arrays bridge pre-hydration gaps.
        cachedAssignments.isEmpty ? viewModel.activeAssignments : cachedAssignments
    }

    private func syncLiveSelections() {
        // WHY recordName re-resolve: live rows are distinct instances so selection tracks identity by key.
        if let name = selectedTemplate?.recordName {
            selectedTemplate = liveTemplates.first { $0.recordName == name } ?? selectedTemplate
        } else if mode.isCreateMode {
            selectedTemplate = liveTemplates.first { $0.isActive }
        }
        if let name = selectedHero?.recordName {
            selectedHero = liveHeroes.first { $0.recordName == name } ?? selectedHero
        } else {
            selectedHero = selectedHero ?? liveHeroes.first
        }
        if case .edit = mode, editAssignee == nil, let quest = editQuestCache {
            editAssignee = liveHeroes.first { $0.recordName == quest.assigneeRecordName }
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
            approvalOverride: $approvalOverride,
            isAllOrNothingOverride: $templateIsAllOrNothing
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
            quickIsAllOrNothing: $quickIsAllOrNothing,
            quickApproval: $quickApproval,
            postToBoard: $quickPostToBoard
        )
    }

    // MARK: - Edit sections

    /// WHY split edit form: the combined Section chain stalls the Swift 6 type-checker.
    private var editSections: some View {
        QuestAssignmentEditFormView(
            questName: $editQuestName,
            questDescription: $editQuestDescription,
            goldText: $editGoldText,
            xpText: $editXpText,
            schedule: $editSchedule,
            specificDays: $editSpecificDays,
            targetCount: $editTargetCount,
            isAllOrNothing: $editIsAllOrNothing,
            approval: $editApproval,
            assignee: $editAssignee,
            propagateToTemplate: $propagateToTemplate,
            showOverrideAlert: $showOverrideAlert,
            isEditAmountFocused: $isEditAmountFocused,
            heroes: liveHeroes,
            hasLogs: editHasLogs,
            allowLockedOverride: allowLockedFieldsOverride
        )
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
            return (selectedHero == nil && !quickPostToBoard) || quickName.trimmingCharacters(in: .whitespaces).isEmpty
        case .edit:
            return editAssignee == nil
        }
    }

    // MARK: - On Appear

    private func performOnAppear() {
        switch mode {
        case .fromTemplate:
            if selectedTemplate == nil {
                selectedTemplate = liveTemplates.first { $0.isActive }
            }
            if selectedHero == nil {
                selectedHero = liveHeroes.first
            }
            userEditedQuestName = false
            // Pre-fill template name and All-or-Nothing
            editQuestName = selectedTemplate?.name ?? ""
            templateIsAllOrNothing = selectedTemplate?.isAllOrNothing ?? false
        case .quickCreate:
            if selectedHero == nil {
                selectedHero = liveHeroes.first
            }
        case let .edit(questRecordName):
            loadQuestForEditing(questRecordName: questRecordName)
        }
    }

    private func loadQuestForEditing(questRecordName: String) {
        guard let quest = liveAssignments.first(where: { $0.recordName == questRecordName }) else { return }
        editQuestCache = quest
        // Edited quest name must not be clobbered by template selection
        userEditedQuestName = true
        editQuestName = quest.questName
        editQuestDescription = quest.descriptionText ?? ""
        editGoldText = CurrencyFormatter.editingString(quest.goldReward)
        editXpText = "\(quest.xpReward)"
        editSchedule = quest.scheduleTypeEnum ?? .weeklyFlexible
        editTargetCount = quest.targetCount
        editIsAllOrNothing = quest.isAllOrNothing
        editApproval = quest.approvalModeEnum ?? .autoApprove

        if let template = liveTemplates.first(where: { $0.recordName == quest.templateRecordName }) {
            editSpecificDays = Set(template.specificDays ?? [])
        } else {
            editSpecificDays = []
        }

        // Resolve assignee from heroes list
        editAssignee = liveHeroes.first { $0.recordName == quest.assigneeRecordName }

        // Check if quest has logs (determines locked fields) synchronously from cache
        editHasLogs = cachedCompletions.contains { $0.questRecordName == quest.recordName }
    }

    private func refreshEditLock() {
        guard case let .edit(questRecordName) = mode else { return }
        // WHY: completions hydrate after the sheet appears; re-evaluate the lock so reward fields don't stay editable.
        editHasLogs = cachedCompletions.contains { $0.questRecordName == questRecordName }
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

        // WHY shared parser: comma decimals must parse in every locale.
        let gold: Int64? = {
            guard let value = CurrencyFormatter.pennies(from: goldOverrideText),
                  value >= 0 else { return nil }
            return value
        }()
        // Legacy RPG chrome hidden when FeatureFlags.rpgImmersive is false.
        let xp: Int? = FeatureFlags.rpgImmersive ? Int(xpOverrideText.trimmingCharacters(in: .whitespaces)) : nil
        let approval: ApprovalMode? = switch approvalOverride {
        case .useTemplate: nil
        case .autoApproveOverride: .autoApprove
        case .parentVerifyOverride: .parentVerify
        }

        let isTemplateMultiOccurrence = QuestSchedule.isMultiOccurrence(
            schedule: template.scheduleTypeEnum ?? .weeklyFlexible,
            targetCount: template.targetCount,
            specificDays: template.specificDays
        )
        let allOrNothingOverride: Bool? = isTemplateMultiOccurrence ? templateIsAllOrNothing : false

        // Template name override: use editQuestName if non-empty, else nil (falls back to template.name)
        let nameOverride = editQuestName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : editQuestName

        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: template)
        // WHY snapshot: @Model rows cannot cross isolation; Sendable structs ride the Task.
        let templateSnapshot = template.toQuestTemplate(zoneID: zoneID)
        let heroSnapshot = hero.toProfile(zoneID: zoneID)
        let overridesSnapshot = (gold: gold, xp: xp, approval: approval, allOrNothing: allOrNothingOverride, name: nameOverride)
        let weekSnapshot = weekOf
        let onCancelSnapshot = onCancel
        isSubmitting = true
        // WHY MainActor view: isSubmitting mutates on the isolated task so Sendable captures stay race-free.
        Task { @MainActor [viewModel, templateSnapshot, heroSnapshot, overridesSnapshot, weekSnapshot, onCancelSnapshot, toastManager, dismiss, logger] in
            do {
                try await viewModel.assignQuest(
                    template: templateSnapshot,
                    assignee: heroSnapshot,
                    goldOverride: overridesSnapshot.gold,
                    xpOverride: overridesSnapshot.xp,
                    approvalOverride: overridesSnapshot.approval,
                    isAllOrNothingOverride: overridesSnapshot.allOrNothing,
                    nameOverride: overridesSnapshot.name,
                    weekOf: weekSnapshot
                )
                isSubmitting = false
                if let onCancelSnapshot {
                    onCancelSnapshot()
                } else {
                    dismiss()
                }
            } catch {
                isSubmitting = false
                logger.error("Failed to assign quest from template: \(error, privacy: .private)")
                toastManager.show(message: "Could not assign the quest. Please try again.", type: .error)
            }
        }
    }

    private func submitQuickCreate() {
        guard !quickPostToBoard else {
            submitPostToBoard()
            return
        }
        guard let hero = selectedHero else {
            toastManager.show(message: "Select a hero.", type: .error)
            return
        }
        let trimmedName = quickName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            toastManager.show(message: "Quest name is required.", type: .error)
            return
        }
        guard let gold = CurrencyFormatter.pennies(from: quickGoldText), gold >= 0 else {
            toastManager.show(message: "Reward must be a valid non-negative number.", type: .error)
            return
        }

        // Legacy RPG chrome hidden when FeatureFlags.rpgImmersive is false.
        let xp = FeatureFlags.rpgImmersive ? quickRarity.xpReward : AppConstants.Rarity.commonXP

        if quickSchedule == .specificDays, quickSpecificDays.isEmpty {
            toastManager.show(message: "Select at least one day for specific-days schedule.", type: .error)
            return
        }

        let isQuickMultiOccurrence = QuestSchedule.isMultiOccurrence(
            schedule: quickSchedule,
            targetCount: quickTargetCount,
            specificDaysCount: quickSpecificDays.count
        )
        let effectiveAllOrNothing = isQuickMultiOccurrence ? quickIsAllOrNothing : false

        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: hero)
        // WHY snapshot: @Model rows cannot cross isolation; Sendable structs ride the Task.
        let heroSnapshot = hero.toProfile(zoneID: zoneID)
        let inputSnapshot = (
            name: trimmedName,
            description: quickDescription,
            gold: gold,
            xp: xp,
            schedule: quickSchedule,
            days: Array(quickSpecificDays),
            target: quickSchedule == .weeklyFlexible ? max(1, quickTargetCount) : 1,
            allOrNothing: effectiveAllOrNothing,
            approval: quickApproval,
            week: weekOf
        )
        let onCancelSnapshot = onCancel
        isSubmitting = true
        // WHY MainActor view: isSubmitting mutates on the isolated task so Sendable captures stay race-free.
        Task { @MainActor [viewModel, heroSnapshot, inputSnapshot, onCancelSnapshot, toastManager, dismiss, logger] in
            let input = QuestManagerViewModel.QuickQuestInput(
                name: inputSnapshot.name,
                description: inputSnapshot.description,
                assignee: heroSnapshot,
                goldReward: inputSnapshot.gold,
                xpReward: inputSnapshot.xp,
                scheduleType: inputSnapshot.schedule,
                specificDays: inputSnapshot.days,
                targetCount: inputSnapshot.target,
                isAllOrNothing: inputSnapshot.allOrNothing,
                approvalMode: inputSnapshot.approval,
                weekOf: inputSnapshot.week
            )
            do {
                try await viewModel.assignQuickQuest(input)
                isSubmitting = false
                if let onCancelSnapshot {
                    onCancelSnapshot()
                } else {
                    dismiss()
                }
            } catch {
                isSubmitting = false
                logger.error("Failed to create quest: \(error, privacy: .private)")
                toastManager.show(message: "Could not create the quest. Please try again.", type: .error)
            }
        }
    }

    /// Board posts skip assignee and due-date concerns entirely — the first
    /// hero to claim owns the quest from that moment on.
    private func submitPostToBoard() {
        let trimmedName = quickName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            toastManager.show(message: "Quest name is required.", type: .error)
            return
        }
        guard let gold = CurrencyFormatter.pennies(from: quickGoldText), gold >= 0 else {
            toastManager.show(message: "Reward must be a valid non-negative number.", type: .error)
            return
        }

        // WHY snapshot: @State values cross suspension; Sendable copies ride the Task.
        let nameSnapshot = trimmedName
        let descriptionSnapshot = quickDescription
        let goldSnapshot = gold
        let xpSnapshot = FeatureFlags.rpgImmersive ? quickRarity.xpReward : AppConstants.Rarity.commonXP
        let approvalSnapshot = quickApproval
        let onCancelSnapshot = onCancel
        isSubmitting = true
        // WHY MainActor view: isSubmitting mutates on the isolated task so Sendable captures stay race-free.
        Task { @MainActor [viewModel, nameSnapshot, descriptionSnapshot, goldSnapshot, xpSnapshot, approvalSnapshot, onCancelSnapshot, toastManager, dismiss, logger] in
            do {
                try await viewModel.postQuestToBoard(
                    name: nameSnapshot,
                    description: descriptionSnapshot,
                    goldReward: goldSnapshot,
                    xpReward: xpSnapshot,
                    approvalMode: approvalSnapshot
                )
                isSubmitting = false
                if let onCancelSnapshot {
                    onCancelSnapshot()
                } else {
                    dismiss()
                }
            } catch {
                isSubmitting = false
                logger.error("Failed to post quest to Hero Board: \(error, privacy: .private)")
                toastManager.show(message: "Could not post the quest to the Hero Board. Please try again.", type: .error)
            }
        }
    }

    private func submitEdit() {
        guard let questCache = editQuestCache else {
            toastManager.show(message: "No quest to edit.", type: .error)
            return
        }
        guard let hero = editAssignee else {
            toastManager.show(message: "Select a hero.", type: .error)
            return
        }

        guard let gold = CurrencyFormatter.pennies(from: editGoldText), gold >= 0 else {
            toastManager.show(message: "Reward must be a valid non-negative number.", type: .error)
            return
        }
        // Legacy RPG chrome hidden when FeatureFlags.rpgImmersive is false.
        let xp: Int
        if FeatureFlags.rpgImmersive {
            guard let parsed = Int(editXpText.trimmingCharacters(in: .whitespaces)), parsed >= 0 else {
                toastManager.show(message: "Bonus reward must be a valid non-negative number.", type: .error)
                return
            }
            xp = parsed
        } else {
            xp = AppConstants.Rarity.commonXP
        }

        if editSchedule == .specificDays, editSpecificDays.isEmpty {
            toastManager.show(message: "Select at least one day for specific-days schedule.", type: .error)
            return
        }

        let name = editQuestName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : editQuestName
        let description = editQuestDescription.trimmingCharacters(in: .whitespaces).isEmpty ? nil : editQuestDescription

        let isEditMulti = QuestSchedule.isMultiOccurrence(schedule: editSchedule, targetCount: editTargetCount, specificDaysCount: editSpecificDays.count)
        let effectiveAllOrNothing = isEditMulti ? editIsAllOrNothing : false

        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: questCache)
        // WHY snapshot: @Model rows cannot cross isolation; Sendable structs ride the Task.
        let questSnapshot = questCache.toQuest(zoneID: zoneID)
        let heroSnapshot = hero.toProfile(zoneID: zoneID)
        let inputSnapshot = (
            name: name,
            description: description,
            gold: gold,
            xp: xp,
            schedule: editSchedule,
            days: Array(editSpecificDays),
            target: editSchedule == .weeklyFlexible ? max(1, editTargetCount) : 1,
            allOrNothing: effectiveAllOrNothing,
            approval: editApproval,
            allowOverride: allowLockedFieldsOverride,
            propagate: propagateToTemplate
        )
        let onCancelSnapshot = onCancel
        isSubmitting = true
        // WHY MainActor view: isSubmitting mutates on the isolated task so Sendable captures stay race-free.
        Task { @MainActor [viewModel, questSnapshot, heroSnapshot, inputSnapshot, onCancelSnapshot, toastManager, dismiss, logger] in
            let input = QuestManagerViewModel.UpdateQuestInput(
                name: inputSnapshot.name,
                descriptionText: inputSnapshot.description,
                goldReward: inputSnapshot.gold,
                xpReward: inputSnapshot.xp,
                scheduleType: inputSnapshot.schedule,
                specificDays: inputSnapshot.days,
                targetCount: inputSnapshot.target,
                isAllOrNothing: inputSnapshot.allOrNothing,
                approvalMode: inputSnapshot.approval,
                assignee: heroSnapshot,
                allowLockedFieldsOverride: inputSnapshot.allowOverride,
                propagateToTemplate: inputSnapshot.propagate
            )
            do {
                try await viewModel.updateQuest(questSnapshot, input: input)
                isSubmitting = false
                if let onCancelSnapshot {
                    onCancelSnapshot()
                } else {
                    dismiss()
                }
            } catch {
                isSubmitting = false
                logger.error("Failed to update quest: \(error, privacy: .private)")
                toastManager.show(message: "Could not update the quest. Please try again.", type: .error)
            }
        }
    }

    private static func defaultWeekOf() -> Date {
        WeekMath.mondayOfWeek(for: Date())
    }
}
