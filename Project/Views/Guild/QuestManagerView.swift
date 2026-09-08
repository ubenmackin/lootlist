//
//  QuestManagerView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct QuestManagerView: View {
    @Environment(ToastManager.self) private var toastManager
    @Environment(AppState.self) private var appState
    @Environment(FamilyService.self) private var familyService
    @Environment(QuestService.self) private var questService
    @Environment(AppSyncCoordinator.self) private var appSyncCoordinator
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Query private var cachedTemplates: [QuestTemplateCache]
    @Query private var cachedAssignments: [QuestCache]
    @Query private var cachedProfiles: [ProfileCache]

    @State private var viewModel: QuestManagerViewModel?
    @State private var selectedTab: ManagerTab = .assignments

    @State private var showAssignSheet: Bool = false
    @State private var showAddTemplateSheet: Bool = false
    struct SheetRecordID: Identifiable {
        let id: String
    }

    @State private var editingTemplateCache: QuestTemplateCache?
    @State private var editingQuestID: SheetRecordID?
    @State private var isSubmitting = false

    // WHY: 3-column inspector keeps table context visible while editing — sheets would hide the sorted list on iPad.
    @State private var searchText = ""
    @State private var sidebarSelection: SidebarSelection = .allHeroes
    @State private var selectedTemplateID: Set<PersistentIdentifier> = []
    @State private var selectedAssignmentID: Set<PersistentIdentifier> = []
    @State private var inspectorNewKind: InspectorNewKind?
    @State private var templateSortOrder: [KeyPathComparator<QuestTemplateCache>] = [
        KeyPathComparator(\QuestTemplateCache.name, order: .forward)
    ]
    @State private var assignmentSortOrder: [KeyPathComparator<QuestCache>] = [
        KeyPathComparator(\QuestCache.questName, order: .forward)
    ]
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    private let familyRecordName: String?

    enum ManagerTab: String, CaseIterable, Identifiable {
        case assignments = "Assignments"
        case templates = "Templates"
        var id: String {
            rawValue
        }
    }

    enum SidebarSelection: Hashable {
        case allHeroes
        case hero(String)
        case templatesActive
        case templatesArchived
    }

    enum InspectorNewKind: Hashable {
        case template
        case assignment
    }

    init(familyRecordName: String? = nil) {
        self.familyRecordName = familyRecordName

        // Filter queries by family at the SwiftData store layer. When familyRecordName is nil,
        // scope to an empty string ("") so zero rows are returned rather than fetching unscoped across all families.
        let targetFamily = familyRecordName ?? ""
        let templateFilter = QuestTemplateCache.activeFamilyPredicate(familyRecordName: targetFamily)
        let assignmentFilter = QuestCache.familyPredicate(familyRecordName: targetFamily)
        let profileFilter = ProfileCache.familyPredicate(familyRecordName: targetFamily)

        _cachedTemplates = Query(
            filter: templateFilter,
            sort: \QuestTemplateCache.name
        )
        _cachedAssignments = Query(
            filter: assignmentFilter,
            sort: \QuestCache.weekOf,
            order: .reverse
        )
        _cachedProfiles = Query(
            filter: profileFilter,
            sort: \ProfileCache.displayName
        )
    }

    var body: some View {
        if horizontalSizeClass == .regular {
            regularLayout
        } else {
            compactLayout
        }
    }

    // MARK: - Regular (iPad) Layout: 3-column NavigationSplitView

    private var regularLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationTitle("Manage")
                .searchable(text: $searchText, prompt: "Search quests & templates")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            // WHY: inspector keeps list visible — sheet would hide the table on iPad.
                            clearInspectorSelection()
                            switch sidebarSelection {
                            case .templatesActive, .templatesArchived:
                                inspectorNewKind = .template
                            default:
                                inspectorNewKind = .assignment
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(isSubmitting)
                        .accessibilityLabel("New")
                        #if !os(tvOS)
                            .keyboardShortcut("n", modifiers: .command)
                        #endif
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        NavigationLink {
                            QuestLogView(familyRecordName: familyRecordName)
                                .environment(questService)
                                .environment(familyService)
                                .environment(appState)
                                .environment(appSyncCoordinator)
                        } label: {
                            Label("Quest Log", systemImage: "scroll")
                        }
                    }
                }
        } content: {
            contentColumn
        } detail: {
            inspectorColumn
        }
        .task {
            ensureViewModel()
            await lifecycleCoordinator?.performManualSync()
        }
        .refreshable {
            await lifecycleCoordinator?.performManualSync()
            rebuildViewModel()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                rebuildViewModel()
            }
        }
        .onChange(of: cachedTemplates) { _, _ in
            rebuildViewModel()
        }
        .onChange(of: cachedAssignments) { _, _ in
            rebuildViewModel()
        }
        .onChange(of: cachedProfiles) { _, _ in
            rebuildViewModel()
        }
        .onChange(of: sidebarSelection) { _, _ in
            clearInspectorSelection()
        }
        .onAppear {
            checkPendingQuickAction(appState.pendingQuickAction)
        }
        .onChange(of: appState.pendingQuickAction) { _, action in
            checkPendingQuickAction(action)
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if let vm = viewModel {
            QuestManagerSidebarView(
                viewModel: vm,
                selection: $sidebarSelection,
                searchText: searchText,
                onAssign: { template, hero in
                    Task { @MainActor @Sendable [template, hero] in
                        await assignTemplate(template, to: hero)
                    }
                }
            )
        } else {
            ProgressView()
        }
    }

    private var contentColumn: some View {
        Group {
            if let vm = viewModel {
                QuestManagerListSectionView(
                    viewModel: vm,
                    sidebarSelection: sidebarSelection,
                    searchText: searchText,
                    selectedTemplateID: $selectedTemplateID,
                    selectedAssignmentID: $selectedAssignmentID,
                    inspectorNewKind: $inspectorNewKind,
                    templateSortOrder: $templateSortOrder,
                    assignmentSortOrder: $assignmentSortOrder,
                    isSubmitting: isSubmitting,
                    familyRecordName: familyRecordName ?? appState.family?.id.recordName,
                    sweepDeferred: vm.sweepDeferred,
                    isAssignmentsEmpty: cachedAssignments.isEmpty,
                    isSyncing: lifecycleCoordinator?.isSyncing == true,
                    onEditTemplate: { editingTemplateCache = $0 },
                    onEditQuest: { editingQuestID = SheetRecordID(id: $0) },
                    onDeactivateTemplate: { handleDeactivateTemplate($0) },
                    onReactivateTemplate: { handleReactivateTemplate($0) },
                    onUnassignQuest: { handleUnassignQuest($0) }
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension QuestManagerView {
    private var inspectorColumn: some View {
        Group {
            if let vm = viewModel {
                QuestManagerInspectorView(
                    viewModel: vm,
                    selectedTemplateID: selectedTemplateID,
                    selectedAssignmentID: selectedAssignmentID,
                    inspectorNewKind: inspectorNewKind,
                    familyRecordName: familyRecordName,
                    onClear: { clearInspectorSelection() }
                )
            } else {
                ProgressView()
            }
        }
    }

    // MARK: - Compact (iPhone) Layout: existing Picker + List

    private var compactLayout: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabPicker
                if let vm = viewModel {
                    switch selectedTab {
                    case .assignments:
                        assignmentsTab(vm: vm)
                    case .templates:
                        templatesTab(vm: vm)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(DesignSystemConstants.Colors.background))
            .navigationTitle("Manage")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search quests & templates")
            .task {
                ensureViewModel()
                await lifecycleCoordinator?.performManualSync()
            }
            .refreshable {
                await lifecycleCoordinator?.performManualSync()
                rebuildViewModel()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    rebuildViewModel()
                }
            }
            .onChange(of: cachedTemplates) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedAssignments) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedProfiles) { _, _ in
                rebuildViewModel()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        QuestLogView(familyRecordName: familyRecordName)
                            .environment(questService)
                            .environment(familyService)
                            .environment(appState)
                            .environment(appSyncCoordinator)
                    } label: {
                        Label("Quest Log", systemImage: "scroll")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        switch selectedTab {
                        case .assignments: showAssignSheet = true
                        case .templates: showAddTemplateSheet = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(isSubmitting)
                    .accessibilityLabel(selectedTab == .assignments ? "Assign New Quest" : "New Template")
                    #if !os(tvOS)
                        .keyboardShortcut("n", modifiers: .command)
                    #endif
                }
            }
            .sheet(isPresented: $showAssignSheet) {
                if let vm = viewModel {
                    QuestAssignmentView(viewModel: vm, familyRecordName: appState.family?.id.recordName)
                }
            }
            .sheet(item: $editingTemplateCache) { template in
                if let vm = viewModel {
                    TemplateManagerView(viewModel: vm, editing: template)
                }
            }
            .sheet(item: $editingQuestID) { item in
                if let vm = viewModel {
                    QuestAssignmentView(mode: .edit(questRecordName: item.id), viewModel: vm, familyRecordName: appState.family?.id.recordName)
                }
            }
            .sheet(isPresented: $showAddTemplateSheet) {
                if let vm = viewModel {
                    TemplateManagerView(viewModel: vm, editing: nil)
                }
            }
            .onAppear {
                checkPendingQuickAction(appState.pendingQuickAction)
            }
            .onChange(of: appState.pendingQuickAction) { _, action in
                checkPendingQuickAction(action)
            }
        }
    }

    private func assignmentsTab(vm: QuestManagerViewModel) -> some View {
        let visible = filteredAssignments(vm: vm)
        return VStack(spacing: 0) {
            // WHY: deferred expiry leaves past-week quests active; banner signals stale state until next reconcileCacheFromCloudKit retries.
            if let familyName = familyRecordName ?? appState.family?.id.recordName,
               !familyName.isEmpty,
               vm.sweepDeferred || cachedAssignments.isEmpty
            {
                StaleDataBanner(
                    family: familyName,
                    type: .quest,
                    count: cachedAssignments.count,
                    isSyncing: lifecycleCoordinator?.isSyncing == true
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            List {
                if visible.isEmpty {
                    emptyAssignmentsState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    let grouped = Dictionary(grouping: visible) { $0.assigneeRecordName }
                    let heroRecords = vm.heroes
                    ForEach(Array(grouped.keys.sorted()), id: \.self) { heroID in
                        let heroQuests = grouped[heroID] ?? []
                        let hero = heroRecords.first { $0.recordName == heroID }
                        Section(header: Text(hero?.displayName ?? "Unknown Hero")) {
                            ForEach(heroQuests) { quest in
                                assignmentRow(quest: quest, vm: vm)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func assignmentRow(quest: QuestCache, vm: QuestManagerViewModel) -> some View {
        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: quest)
        // WHY snapshot: @Model rows cannot cross isolation; Sendable struct rides the Task.
        let questSnapshot = quest.toQuest(zoneID: zoneID)
        let approvalMode = quest.approvalModeEnum ?? .autoApprove
        return Button {
            if horizontalSizeClass == .regular {
                selectedAssignmentID = [quest.persistentModelID]
                selectedTemplateID = []
                inspectorNewKind = nil
            } else {
                editingQuestID = SheetRecordID(id: quest.recordName)
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
                    editingQuestID = SheetRecordID(id: quest.recordName)
                }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                guard !isSubmitting else { return }
                isSubmitting = true
                Task { @MainActor @Sendable [questSnapshot] in
                    defer { isSubmitting = false }
                    do {
                        try await vm.unassignQuest(questSnapshot)
                    } catch {
                        toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                    }
                }
            } label: {
                Label("Unassign", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                guard !isSubmitting else { return }
                isSubmitting = true
                Task { @MainActor @Sendable [questSnapshot] in
                    defer { isSubmitting = false }
                    do {
                        try await vm.unassignQuest(questSnapshot)
                    } catch {
                        toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                    }
                }
            } label: {
                Label("Unassign", systemImage: "trash")
            }
            .disabled(isSubmitting)
        }
    }

    private var emptyAssignmentsState: some View {
        EmptyStateView(
            systemImage: "calendar.badge.exclamationmark",
            title: "No active assignments for this week",
            description: "Tap “Assign New Quest” to send a quest to a hero.",
            verticalPadding: 64
        )
    }

    private func templatesTab(vm: QuestManagerViewModel) -> some View {
        let visible = filteredTemplates(vm: vm)
        return List {
            if visible.isEmpty {
                emptyTemplatesState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(visible) { template in
                    templateRow(template: template, vm: vm)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func templateRow(template: QuestTemplateCache, vm: QuestManagerViewModel) -> some View {
        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: template)
        // WHY snapshot: @Model rows cannot cross isolation; Sendable struct rides the Task.
        let templateSnapshot = template.toQuestTemplate(zoneID: zoneID)
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
                editingTemplateCache = template
            }
        }
        .contextMenu {
            Button {
                if horizontalSizeClass == .regular {
                    selectedTemplateID = [template.persistentModelID]
                    selectedAssignmentID = []
                    inspectorNewKind = nil
                } else {
                    editingTemplateCache = template
                }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            if template.isActive {
                Button {
                    guard !isSubmitting else { return }
                    isSubmitting = true
                    Task { @MainActor @Sendable [templateSnapshot] in
                        defer { isSubmitting = false }
                        do {
                            try await vm.deactivateTemplate(templateSnapshot)
                        } catch {
                            toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                        }
                    }
                } label: {
                    Label("Deactivate", systemImage: "trash.slash")
                }
            } else {
                Button {
                    guard !isSubmitting else { return }
                    isSubmitting = true
                    Task { @MainActor @Sendable [templateSnapshot] in
                        defer { isSubmitting = false }
                        do {
                            try await vm.reactivateTemplate(templateSnapshot)
                        } catch {
                            toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                        }
                    }
                } label: {
                    Label("Activate", systemImage: "arrow.clockwise.circle.fill")
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if template.isActive {
                Button {
                    guard !isSubmitting else { return }
                    isSubmitting = true
                    Task { @MainActor @Sendable [templateSnapshot] in
                        defer { isSubmitting = false }
                        do {
                            try await vm.deactivateTemplate(templateSnapshot)
                        } catch {
                            toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                        }
                    }
                } label: {
                    Label("Deactivate", systemImage: "trash.slash")
                }
                .disabled(isSubmitting)
                .tint(Color(DesignSystemConstants.Colors.pendingAmber))
            } else {
                Button {
                    guard !isSubmitting else { return }
                    isSubmitting = true
                    Task { @MainActor @Sendable [templateSnapshot] in
                        defer { isSubmitting = false }
                        do {
                            try await vm.reactivateTemplate(templateSnapshot)
                        } catch {
                            toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                        }
                    }
                } label: {
                    Label("Activate", systemImage: "arrow.clockwise.circle.fill")
                }
                .disabled(isSubmitting)
                .tint(Color(DesignSystemConstants.Colors.primaryGreen))
            }
        }
    }

    private var emptyTemplatesState: some View {
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
    }
}

// MARK: - Lifecycle (consolidated for encapsulation — was QuestManagerView+Lifecycle.swift)

extension QuestManagerView {
    private func checkPendingQuickAction(_ action: QuickActionType?) {
        guard let action else { return }
        switch action {
        case .addQuickQuest:
            if horizontalSizeClass == .regular {
                sidebarSelection = .allHeroes
                inspectorNewKind = .assignment
            } else {
                selectedTab = .assignments
                showAssignSheet = true
            }
            appState.pendingQuickAction = nil
        case .addTemplate:
            if horizontalSizeClass == .regular {
                sidebarSelection = .templatesActive
                inspectorNewKind = .template
            } else {
                selectedTab = .templates
                showAddTemplateSheet = true
            }
            appState.pendingQuickAction = nil
        default:
            break
        }
    }

    private func ensureViewModel() {
        ViewLifecycle.ensureAndRebuild(&viewModel, factory: {
            QuestManagerViewModel(
                questService: questService,
                familyService: familyService,
                appState: appState
            )
        }, rebuild: { vm in rebuildViewModel(vm) })
    }

    private func rebuildViewModel(_ vm: QuestManagerViewModel? = nil) {
        guard let targetVM = vm ?? viewModel else { return }
        targetVM.rebuildLists(templates: cachedTemplates, assignments: cachedAssignments)
        targetVM.rebuildHeroes(profiles: cachedProfiles)
    }

    private var tabPicker: some View {
        Picker("Sections", selection: $selectedTab) {
            ForEach(ManagerTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Filtering & Sorting (consolidated — was QuestManagerView+Filtering.swift)

extension QuestManagerView {
    private func filteredTemplates(vm: QuestManagerViewModel) -> [QuestTemplateCache] {
        let base: [QuestTemplateCache] = switch sidebarSelection {
        case .templatesActive:
            vm.templates.filter(\.isActive)
        case .templatesArchived:
            vm.templates.filter { !$0.isActive }
        case .allHeroes, .hero:
            vm.templates
        }
        return applySearch(toTemplates: base)
    }

    private func filteredTemplatesForCounts(vm: QuestManagerViewModel, isActive: Bool) -> [QuestTemplateCache] {
        let base = vm.templates.filter { $0.isActive == isActive }
        return applySearch(toTemplates: base)
    }

    /// Generic search — centralizes trimming/lowercasing/filter logic used by both template and assignment lists.
    private func applySearch<T>(to items: [T], query: String, selectors: [(T) -> String]) -> [T] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        let lower = trimmed.lowercased()
        return items.filter { item in
            selectors.contains { selector in selector(item).lowercased().contains(lower) }
        }
    }

    private func applySearch(toTemplates templates: [QuestTemplateCache]) -> [QuestTemplateCache] {
        applySearch(to: templates, query: searchText, selectors: [{ $0.name }])
    }

    private func filteredAssignments(vm: QuestManagerViewModel) -> [QuestCache] {
        let base: [QuestCache] = switch sidebarSelection {
        case .allHeroes:
            vm.activeAssignments
        case let .hero(recordName):
            vm.activeAssignments.filter { $0.assigneeRecordName == recordName }
        case .templatesActive, .templatesArchived:
            vm.activeAssignments
        }
        return applySearch(toAssignments: base, vm: vm)
    }

    private func filteredAssignmentsForCounts(vm: QuestManagerViewModel, heroRecordName: String?) -> [QuestCache] {
        let base: [QuestCache] = if let heroRecordName {
            vm.activeAssignments.filter { $0.assigneeRecordName == heroRecordName }
        } else {
            vm.activeAssignments
        }
        return applySearch(toAssignments: base, vm: vm)
    }

    private func applySearch(toAssignments assignments: [QuestCache], vm: QuestManagerViewModel) -> [QuestCache] {
        applySearch(to: assignments, query: searchText, selectors: [{ $0.questName }, { self.heroName(for: $0.assigneeRecordName, vm: vm) }])
    }

    private func sortedTemplates(_ templates: [QuestTemplateCache]) -> [QuestTemplateCache] {
        templates.sorted(using: templateSortOrder)
    }

    private func sortedAssignments(_ assignments: [QuestCache], vm _: QuestManagerViewModel) -> [QuestCache] {
        assignments.sorted(using: assignmentSortOrder)
    }

    private func heroName(for recordName: String, vm: QuestManagerViewModel) -> String {
        vm.heroName(for: recordName)
    }

    @MainActor
    private func handleDeactivateTemplate(_ template: QuestTemplateCache) {
        guard !isSubmitting, let vm = viewModel else { return }
        isSubmitting = true
        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: template)
        // WHY snapshot: @Model rows cannot cross isolation; Sendable struct rides the Task.
        let snapshot = template.toQuestTemplate(zoneID: zoneID)
        Task { @MainActor @Sendable [snapshot] in
            defer { isSubmitting = false }
            do {
                try await vm.deactivateTemplate(snapshot)
            } catch {
                toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
            }
        }
    }

    @MainActor
    private func handleReactivateTemplate(_ template: QuestTemplateCache) {
        guard !isSubmitting, let vm = viewModel else { return }
        isSubmitting = true
        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: template)
        // WHY snapshot: @Model rows cannot cross isolation; Sendable struct rides the Task.
        let snapshot = template.toQuestTemplate(zoneID: zoneID)
        Task { @MainActor @Sendable [snapshot] in
            defer { isSubmitting = false }
            do {
                try await vm.reactivateTemplate(snapshot)
            } catch {
                toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
            }
        }
    }

    @MainActor
    private func handleUnassignQuest(_ quest: QuestCache) {
        guard !isSubmitting, let vm = viewModel else { return }
        isSubmitting = true
        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: quest)
        // WHY snapshot: @Model rows cannot cross isolation; Sendable struct rides the Task.
        let snapshot = quest.toQuest(zoneID: zoneID)
        Task { @MainActor @Sendable [snapshot] in
            defer { isSubmitting = false }
            do {
                try await vm.unassignQuest(snapshot)
            } catch {
                toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
            }
        }
    }

    private func clearInspectorSelection() {
        selectedTemplateID = []
        selectedAssignmentID = []
        inspectorNewKind = nil
    }

    @MainActor
    private func assignTemplate(_ template: QuestTemplate, to hero: Profile) async {
        guard let vm = viewModel else { return }
        do {
            try await vm.assignQuest(
                template: template,
                assignee: hero,
                goldOverride: nil,
                xpOverride: nil,
                approvalOverride: nil,
                isAllOrNothingOverride: nil,
                nameOverride: nil,
                weekOf: WeekMath.startOfWeek(for: Date(), payoutDay: appState.family?.payoutDay ?? .sunday)
            )
        } catch {
            toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
        }
    }
}
