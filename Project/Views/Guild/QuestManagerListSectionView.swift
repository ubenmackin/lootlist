//
//  QuestManagerListSectionView.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Content column extracted from QuestManagerView; table versus list branching
/// and row actions match the parent with no visual change.
struct QuestManagerListSectionView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let viewModel: QuestManagerViewModel
    let sidebarSelection: QuestManagerView.SidebarSelection
    let searchText: String
    @Binding var selectedTemplateID: Set<PersistentIdentifier>
    @Binding var selectedAssignmentID: Set<PersistentIdentifier>
    @Binding var inspectorNewKind: QuestManagerView.InspectorNewKind?
    @Binding var templateSortOrder: [KeyPathComparator<QuestTemplateCache>]
    @Binding var assignmentSortOrder: [KeyPathComparator<QuestCache>]
    let isSubmitting: Bool
    let familyRecordName: String?
    let sweepDeferred: Bool
    let isAssignmentsEmpty: Bool
    let isSyncing: Bool
    let onEditTemplate: (QuestTemplateCache) -> Void
    let onEditQuest: (String) -> Void
    let onDeactivateTemplate: (QuestTemplateCache) -> Void
    let onReactivateTemplate: (QuestTemplateCache) -> Void
    let onUnassignQuest: (QuestCache) -> Void
    /// Compact iPhone tab override; when set, the section renders that tab's list directly.
    let compactTab: QuestManagerView.ManagerTab?

    init(
        viewModel: QuestManagerViewModel,
        sidebarSelection: QuestManagerView.SidebarSelection,
        searchText: String,
        selectedTemplateID: Binding<Set<PersistentIdentifier>>,
        selectedAssignmentID: Binding<Set<PersistentIdentifier>>,
        inspectorNewKind: Binding<QuestManagerView.InspectorNewKind?>,
        templateSortOrder: Binding<[KeyPathComparator<QuestTemplateCache>]>,
        assignmentSortOrder: Binding<[KeyPathComparator<QuestCache>]>,
        isSubmitting: Bool,
        familyRecordName: String?,
        sweepDeferred: Bool,
        isAssignmentsEmpty: Bool,
        isSyncing: Bool,
        onEditTemplate: @escaping (QuestTemplateCache) -> Void,
        onEditQuest: @escaping (String) -> Void,
        onDeactivateTemplate: @escaping (QuestTemplateCache) -> Void,
        onReactivateTemplate: @escaping (QuestTemplateCache) -> Void,
        onUnassignQuest: @escaping (QuestCache) -> Void,
        compactTab: QuestManagerView.ManagerTab? = nil
    ) {
        self.viewModel = viewModel
        self.sidebarSelection = sidebarSelection
        self.searchText = searchText
        self._selectedTemplateID = selectedTemplateID
        self._selectedAssignmentID = selectedAssignmentID
        self._inspectorNewKind = inspectorNewKind
        self._templateSortOrder = templateSortOrder
        self._assignmentSortOrder = assignmentSortOrder
        self.isSubmitting = isSubmitting
        self.familyRecordName = familyRecordName
        self.sweepDeferred = sweepDeferred
        self.isAssignmentsEmpty = isAssignmentsEmpty
        self.isSyncing = isSyncing
        self.onEditTemplate = onEditTemplate
        self.onEditQuest = onEditQuest
        self.onDeactivateTemplate = onDeactivateTemplate
        self.onReactivateTemplate = onReactivateTemplate
        self.onUnassignQuest = onUnassignQuest
        self.compactTab = compactTab
    }

    var body: some View {
        if let compactTab {
            switch compactTab {
            case .assignments:
                assignmentsTab
            case .templates:
                templatesTab
            }
        } else {
            GeometryReader { proxy in
                let width = proxy.size.width
                Group {
                    switch sidebarSelection {
                    case .templatesActive, .templatesArchived:
                        if width > DesignSystemConstants.Layout.iPadTableThreshold {
                            templateTable
                        } else {
                            templatesTab
                        }
                    case .allHeroes, .hero:
                        if width > DesignSystemConstants.Layout.iPadTableThreshold {
                            assignmentTable
                        } else {
                            assignmentsTab
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Tables

    private var templateTable: some View {
        let filtered = filteredTemplates
        let sorted = filtered.sorted(using: templateSortOrder)
        let nameColumn = TableColumn("Name", value: \QuestTemplateCache.name) { template in
            Text(template.name)
                .onDrag { NSItemProvider(object: template.recordName as NSString) }
        }
        let rewardColumn = TableColumn("Reward", value: \QuestTemplateCache.goldReward) { template in
            Text(CurrencyFormatter.string(template.goldReward))
        }
        let scheduleColumn = TableColumn("Schedule", value: \QuestTemplateCache.scheduleType) { template in
            Text(template.scheduleTypeEnum?.displayName ?? template.scheduleType)
        }
        let statusColumn = TableColumn("Status") { (template: QuestTemplateCache) in
            Text(template.isActive ? "Active" : "Archived")
                .foregroundStyle(template.isActive ? Color(DesignSystemConstants.Colors.primaryGreen) : Color.secondary)
        }
        return Table(sorted, selection: $selectedTemplateID, sortOrder: $templateSortOrder) {
            nameColumn
            rewardColumn
            scheduleColumn
            statusColumn
        }
        .onChange(of: selectedTemplateID) { _, newValue in
            if !newValue.isEmpty {
                selectedAssignmentID = []
                inspectorNewKind = nil
            }
        }
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView("No templates", systemImage: "doc.text.magnifyingglass", description: Text("Create reusable quest blueprints to assign to your heroes."))
            }
        }
    }

    private var assignmentTable: some View {
        let filtered = filteredAssignments
        let sorted = filtered.sorted(using: assignmentSortOrder)
        let heroColumn = TableColumn("Hero", value: \QuestCache.assigneeRecordName) { quest in
            Text(viewModel.heroName(for: quest.assigneeRecordName))
        }
        let questColumn = TableColumn("Quest", value: \QuestCache.questName) { quest in
            Text(quest.questName)
        }
        let rewardColumn = TableColumn("Reward", value: \QuestCache.goldReward) { quest in
            Text(CurrencyFormatter.string(quest.goldReward))
        }
        let approvalColumn = TableColumn("Approval", value: \QuestCache.approvalMode) { quest in
            Text(quest.approvalModeEnum?.displayName ?? quest.approvalMode)
        }
        return Table(sorted, selection: $selectedAssignmentID, sortOrder: $assignmentSortOrder) {
            heroColumn
            questColumn
            rewardColumn
            approvalColumn
        }
        .onChange(of: selectedAssignmentID) { _, newValue in
            if !newValue.isEmpty {
                selectedTemplateID = []
                inspectorNewKind = nil
            }
        }
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView("No assignments", systemImage: "calendar.badge.exclamationmark", description: Text("Tap + to assign a quest to a hero."))
            }
        }
    }

    // MARK: - Compact Tabs

    private var assignmentsTab: some View {
        let visible = filteredAssignments
        return VStack(spacing: 0) {
            // WHY: deferred expiry leaves past-week quests active; banner signals stale state until next reconcileCacheFromCloudKit retries.
            if let familyName = familyRecordName, !familyName.isEmpty, sweepDeferred || isAssignmentsEmpty {
                StaleDataBanner(
                    family: familyName,
                    type: .quest,
                    count: isAssignmentsEmpty ? 0 : visible.count,
                    isSyncing: isSyncing
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            List {
                if visible.isEmpty {
                    EmptyStateView(
                        systemImage: "calendar.badge.exclamationmark",
                        title: "No active assignments for this week",
                        description: "Tap “Assign New Quest” to send a quest to a hero.",
                        verticalPadding: 64
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    let grouped = viewModel.groupedAssignments(visible)
                    ForEach(grouped, id: \.key) { entry in
                        let hero = viewModel.heroes.first { $0.recordName == entry.key }
                        Section(header: Text(hero?.displayName ?? "Unknown Hero")) {
                            ForEach(entry.quests) { quest in
                                assignmentRow(quest: quest)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func assignmentRow(quest: QuestCache) -> some View {
        let approvalMode = quest.approvalModeEnum ?? .autoApprove
        return Button {
            if horizontalSizeClass == .regular {
                selectedAssignmentID = [quest.persistentModelID]
                selectedTemplateID = []
                inspectorNewKind = nil
            } else {
                onEditQuest(quest.recordName)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: approvalMode.iconSystemName)
                    .foregroundStyle(approvalMode == .parentVerify ? Color(DesignSystemConstants.Colors.accentBlue) : Color(DesignSystemConstants.Colors.primaryGreen))
                VStack(alignment: .leading, spacing: 2) {
                    Text(quest.questName)
                        .font(.subheadline.bold())
                    Text("\(CurrencyFormatter.string(quest.goldReward)) · \(approvalMode.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            // WHY: List rows leave trailing dead space outside a tight HStack — stretching the label keeps every tap on the row on the Button.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .contextMenu {
            Button {
                if horizontalSizeClass == .regular {
                    selectedAssignmentID = [quest.persistentModelID]
                    selectedTemplateID = []
                    inspectorNewKind = nil
                } else {
                    onEditQuest(quest.recordName)
                }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                guard !isSubmitting else { return }
                onUnassignQuest(quest)
            } label: {
                Label("Unassign", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                guard !isSubmitting else { return }
                onUnassignQuest(quest)
            } label: {
                Label("Unassign", systemImage: "trash")
            }
            .disabled(isSubmitting)
        }
    }

    private var templatesTab: some View {
        let visible = filteredTemplates
        return List {
            if visible.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("No templates yet")
                        .font(.headline)
                    Text("Create reusable quest blueprints to assign to your heroes.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 64)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(visible) { template in
                    templateRow(template: template)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func templateRow(template: QuestTemplateCache) -> some View {
        let scheduleType = template.scheduleTypeEnum ?? .weeklyFlexible
        return HStack(spacing: 12) {
            Image(systemName: scheduleType.iconSystemName)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                    .font(.subheadline.bold())
                Text("\(CurrencyFormatter.string(template.goldReward)) · \(scheduleType.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !template.isActive {
                    Text("Deactivated")
                        .font(.caption2)
                        .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
                }
            }
            Spacer()
        }
        .padding(.vertical, DesignSystemConstants.Padding.small)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .onDrag { NSItemProvider(object: template.recordName as NSString) }
        .onTapGesture {
            if horizontalSizeClass == .regular {
                selectedTemplateID = [template.persistentModelID]
                selectedAssignmentID = []
                inspectorNewKind = nil
            } else {
                onEditTemplate(template)
            }
        }
        .contextMenu {
            Button {
                if horizontalSizeClass == .regular {
                    selectedTemplateID = [template.persistentModelID]
                    selectedAssignmentID = []
                    inspectorNewKind = nil
                } else {
                    onEditTemplate(template)
                }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            if template.isActive {
                Button {
                    guard !isSubmitting else { return }
                    onDeactivateTemplate(template)
                } label: {
                    Label("Deactivate", systemImage: "trash.slash")
                }
            } else {
                Button {
                    guard !isSubmitting else { return }
                    onReactivateTemplate(template)
                } label: {
                    Label("Activate", systemImage: "arrow.clockwise.circle.fill")
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if template.isActive {
                Button {
                    guard !isSubmitting else { return }
                    onDeactivateTemplate(template)
                } label: {
                    Label("Deactivate", systemImage: "trash.slash")
                }
                .disabled(isSubmitting)
                .tint(Color(DesignSystemConstants.Colors.pendingAmber))
            } else {
                Button {
                    guard !isSubmitting else { return }
                    onReactivateTemplate(template)
                } label: {
                    Label("Activate", systemImage: "arrow.clockwise.circle.fill")
                }
                .disabled(isSubmitting)
                .tint(Color(DesignSystemConstants.Colors.primaryGreen))
            }
        }
    }

    // MARK: - Filtering (delegates hero naming to the ViewModel)

    private var filteredTemplates: [QuestTemplateCache] {
        let base: [QuestTemplateCache] = switch sidebarSelection {
        case .templatesActive:
            viewModel.templates.filter(\.isActive)
        case .templatesArchived:
            viewModel.templates.filter { !$0.isActive }
        case .allHeroes, .hero:
            viewModel.templates
        }
        return applySearch(toTemplates: base)
    }

    private var filteredAssignments: [QuestCache] {
        let base: [QuestCache] = switch sidebarSelection {
        case .allHeroes:
            viewModel.activeAssignments
        case let .hero(recordName):
            viewModel.activeAssignments.filter { $0.assigneeRecordName == recordName }
        case .templatesActive, .templatesArchived:
            viewModel.activeAssignments
        }
        return applySearch(toAssignments: base)
    }

    private func applySearch(toTemplates templates: [QuestTemplateCache]) -> [QuestTemplateCache] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return templates }
        let lower = trimmed.lowercased()
        return templates.filter { $0.name.lowercased().contains(lower) }
    }

    private func applySearch(toAssignments assignments: [QuestCache]) -> [QuestCache] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return assignments }
        let lower = trimmed.lowercased()
        return assignments.filter {
            $0.questName.lowercased().contains(lower)
                || viewModel.heroName(for: $0.assigneeRecordName).lowercased().contains(lower)
        }
    }
}
