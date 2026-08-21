//
//  QuestManagerView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import SwiftData
import SwiftUI

struct QuestManagerView: View {
    @Environment(ToastManager.self) private var toastManager
    @Environment(AppState.self) private var appState
    @Environment(FamilyService.self) private var familyService
    @Environment(QuestService.self) private var questService
    @Environment(AppSyncCoordinator.self) private var appSyncCoordinator
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?
    @Environment(\.scenePhase) private var scenePhase

    @Query private var cachedTemplates: [QuestTemplateCache]
    @Query private var cachedAssignments: [QuestCache]
    @Query private var cachedProfiles: [ProfileCache]

    @State private var viewModel: QuestManagerViewModel?
    @State private var selectedTab: ManagerTab = .assignments

    @State private var showAssignSheet: Bool = false
    @State private var showAddTemplateSheet: Bool = false
    @State private var editingTemplate: QuestTemplate?
    @State private var editingQuest: Quest?
    @State private var isSubmitting = false

    /// Family record name used to push the family filter down to SwiftData.
    /// When `nil` (no family loaded) the queries return zero rows, which is
    /// the correct behavior — there is no family to scope to.
    private let familyRecordName: String?

    enum ManagerTab: String, CaseIterable, Identifiable {
        case assignments = "Assignments"
        case templates = "Templates"
        var id: String {
            rawValue
        }
    }

    init(familyRecordName: String? = nil) {
        self.familyRecordName = familyRecordName

        // Filter queries by family at the SwiftData store layer. When familyRecordName is nil,
        // scope to an empty string ("") so zero rows are returned rather than fetching unscoped across all families.
        let targetFamily = familyRecordName ?? ""
        let templateFilter = #Predicate<QuestTemplateCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let assignmentFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let profileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }

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
        NavigationStack {
            VStack(spacing: 0) {
                if let vm = viewModel {
                    tabPicker
                    switch selectedTab {
                    case .assignments:
                        assignmentsTab(vm: vm)
                    case .templates:
                        templatesTab(vm: vm)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Manage")
            .navigationBarTitleDisplayMode(.large)
            .task {
                await lifecycleCoordinator?.performManualSync()
                if viewModel == nil {
                    viewModel = QuestManagerViewModel(
                        questService: questService,
                        familyService: familyService,
                        appState: appState
                    )
                }
                rebuildViewModel()
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
                        Image(systemName: "scroll")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
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
                }
            }
            .sheet(isPresented: $showAssignSheet) {
                if let vm = viewModel {
                    QuestAssignmentView(viewModel: vm)
                }
            }
            .sheet(item: $editingTemplate) { template in
                if let vm = viewModel {
                    TemplateManagerView(viewModel: vm, editing: template)
                }
            }
            .sheet(item: $editingQuest) { quest in
                if let vm = viewModel {
                    QuestAssignmentView(mode: .edit(questID: quest.id), viewModel: vm)
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

    private func checkPendingQuickAction(_ action: QuickActionType?) {
        guard let action else { return }
        switch action {
        case .addQuickQuest:
            selectedTab = .assignments
            showAssignSheet = true
            appState.pendingQuickAction = nil
        case .addTemplate:
            selectedTab = .templates
            showAddTemplateSheet = true
            appState.pendingQuickAction = nil
        default:
            break
        }
    }

    private func rebuildViewModel() {
        guard let vm = viewModel else { return }
        vm.rebuildLists(templates: cachedTemplates, assignments: cachedAssignments)
        vm.rebuildHeroes(profiles: cachedProfiles)
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

    private func assignmentsTab(vm: QuestManagerViewModel) -> some View {
        List {
            if vm.activeAssignments.isEmpty {
                emptyAssignmentsState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                let grouped = Dictionary(grouping: vm.activeAssignments) { $0.assigneeRecordName }
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

    private func assignmentRow(quest: QuestCache, vm: QuestManagerViewModel) -> some View {
        let zoneID = appState.familyZoneID ?? appState.family?.id.zoneID ?? quest.validatedZoneID(requestedZoneID: CKRecordZone.default().zoneID)
        let approvalMode = quest.approvalModeEnum ?? .autoApprove
        let rarity = quest.rarityEnum ?? .common
        return Button {
            editingQuest = quest.toQuest(zoneID: zoneID)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: approvalMode.iconSystemName)
                    .foregroundStyle(approvalMode == .parentVerify ? .indigo : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(quest.questName)
                        .font(.subheadline.bold())
                    Text("\(CurrencyFormatter.string(quest.goldReward)) · \(rarity.rawValue) (\(quest.xpReward) XP) · \(approvalMode.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                guard !isSubmitting else { return }
                isSubmitting = true
                Task {
                    defer { isSubmitting = false }
                    do {
                        try await vm.unassignQuest(quest.toQuest(zoneID: zoneID))
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
        List {
            if vm.templates.isEmpty {
                emptyTemplatesState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(vm.templates) { template in
                    templateRow(template: template, vm: vm)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func templateRow(template: QuestTemplateCache, vm: QuestManagerViewModel) -> some View {
        let zoneID = appState.familyZoneID ?? appState.family?.id.zoneID ?? template.validatedZoneID(requestedZoneID: CKRecordZone.default().zoneID)
        let scheduleType = template.scheduleTypeEnum ?? .weeklyFlexible
        let rarity = template.rarityEnum ?? .common
        return HStack(spacing: 12) {
            Image(systemName: scheduleType.iconSystemName)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                    .font(.subheadline.bold())
                Text("\(CurrencyFormatter.string(template.goldReward)) · \(rarity.rawValue) (\(template.xpReward) XP) · \(scheduleType.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !template.isActive {
                    Text("Deactivated")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            editingTemplate = template.toQuestTemplate(zoneID: zoneID)
        }
        .swipeActions(edge: .trailing) {
            if template.isActive {
                Button {
                    guard !isSubmitting else { return }
                    isSubmitting = true
                    Task {
                        defer { isSubmitting = false }
                        do {
                            try await vm.deactivateTemplate(template.toQuestTemplate(zoneID: zoneID))
                        } catch {
                            toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                        }
                    }
                } label: {
                    Label("Deactivate", systemImage: "trash.slash")
                }
                .disabled(isSubmitting)
                .tint(.orange)
            } else {
                Button {
                    guard !isSubmitting else { return }
                    isSubmitting = true
                    Task {
                        defer { isSubmitting = false }
                        do {
                            try await vm.reactivateTemplate(template.toQuestTemplate(zoneID: zoneID))
                        } catch {
                            toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                        }
                    }
                } label: {
                    Label("Activate", systemImage: "arrow.clockwise.circle.fill")
                }
                .disabled(isSubmitting)
                .tint(.green)
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
