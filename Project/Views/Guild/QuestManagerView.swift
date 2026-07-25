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
    @Environment(AppState.self) private var appState
    @Environment(FamilyService.self) private var familyService
    @Environment(QuestService.self) private var questService
    @Environment(AppSyncCoordinator.self) private var appSyncCoordinator
    @Environment(\.scenePhase) private var scenePhase

    @Query private var cachedTemplates: [QuestTemplateCache]
    @Query private var cachedAssignments: [QuestCache]

    @State private var viewModel: QuestManagerViewModel?
    @State private var selectedTab: ManagerTab = .assignments

    @State private var showAssignSheet: Bool = false
    @State private var showAddTemplateSheet: Bool = false
    @State private var editingTemplate: QuestTemplate?
    @State private var editingQuest: Quest?

    enum ManagerTab: String, CaseIterable, Identifiable {
        case assignments = "Assignments"
        case templates = "Templates"
        var id: String {
            rawValue
        }
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
                if viewModel == nil {
                    viewModel = QuestManagerViewModel(
                        questService: questService,
                        familyService: familyService,
                        appState: appState
                    )
                }
                viewModel?.subscribeToSyncEvents(appSyncCoordinator)
                await viewModel?.load()
                await viewModel?.loadHeroes()
            }
            .refreshable {
                await viewModel?.load()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task {
                        await viewModel?.load()
                        await viewModel?.loadHeroes()
                    }
                }
            }
            .onDisappear {
                viewModel?.unsubscribeFromSyncEvents(appSyncCoordinator)
            }
            .onChange(of: cachedTemplates) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedAssignments) { _, _ in
                rebuildViewModel()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        QuestLogView()
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
        }
    }

    private func rebuildViewModel() {
        guard let vm = viewModel else { return }
        guard let family = appState.family else { return }
        let zoneID = questService.cloudKitReference.resolvedZoneID
        let familyName = family.id.recordName

        let templates = cachedTemplates
            .filter { $0.familyRecordName == familyName }
            .map { $0.toQuestTemplate(zoneID: zoneID) }

        let assignments = cachedAssignments
            .filter { $0.familyRecordName == familyName && $0.isActive }
            .map { $0.toQuest(zoneID: zoneID) }

        vm.rebuildLists(templates: templates, assignments: assignments)
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
                let grouped = Dictionary(grouping: vm.activeAssignments) { $0.assignee.recordID.recordName }
                let heroRecords = vm.heroes
                ForEach(Array(grouped.keys.sorted()), id: \.self) { heroID in
                    let heroQuests = grouped[heroID] ?? []
                    let hero = heroRecords.first { $0.id.recordName == heroID }
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

    private func assignmentRow(quest: Quest, vm: QuestManagerViewModel) -> some View {
        Button {
            editingQuest = quest
        } label: {
            HStack(spacing: 12) {
                Image(systemName: quest.approvalMode.iconSystemName)
                    .foregroundStyle(quest.approvalMode == .parentVerify ? .indigo : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(quest.displayName)
                        .font(.subheadline.bold())
                    Text(String(format: "%.2f gold · %@ (%d XP) · %@",
                                quest.goldReward, quest.rarity.rawValue, quest.xpReward, quest.approvalMode.displayName))
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
                Task { try? await vm.unassignQuest(quest) }
            } label: {
                Label("Unassign", systemImage: "trash")
            }
        }
    }

    private var emptyAssignmentsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No active assignments for this week")
                .font(.headline)
            Text("Tap “Assign New Quest” to send a quest to a hero.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
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

    private func templateRow(template: QuestTemplate, vm: QuestManagerViewModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: template.scheduleType.iconSystemName)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                    .font(.subheadline.bold())
                Text(String(format: "%.2f gold · %@ (%d XP) · %@",
                            template.defaultGold, template.rarity.rawValue, template.xpReward,
                            template.scheduleType.displayName))
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
            editingTemplate = template
        }
        .swipeActions(edge: .trailing) {
            if template.isActive {
                Button {
                    Task { try? await vm.deactivateTemplate(template) }
                } label: {
                    Label("Deactivate", systemImage: "trash.slash")
                }
                .tint(.orange)
            } else {
                Button {
                    Task { try? await vm.reactivateTemplate(template) }
                } label: {
                    Label("Activate", systemImage: "arrow.clockwise.circle.fill")
                }
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
