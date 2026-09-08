//
//  QuestManagerSidebarView.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import SwiftData
import SwiftUI

/// Sidebar extracted from QuestManagerView so the manager composes focused
/// sections with no logic change; counts share the parent filter helpers.
struct QuestManagerSidebarView: View {
    @Environment(AppState.self) private var appState

    let viewModel: QuestManagerViewModel
    @Binding var selection: QuestManagerView.SidebarSelection
    let searchText: String
    let onAssign: (QuestTemplate, Profile) -> Void

    var body: some View {
        List {
            Section("Heroes") {
                let allCount = filteredAssignmentsForCounts(heroRecordName: nil).count
                Button {
                    selection = .allHeroes
                } label: {
                    Label {
                        HStack {
                            Text("All Heroes")
                            Spacer()
                            Text("\(allCount)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "person.3.fill")
                    }
                }
                .tag(QuestManagerView.SidebarSelection.allHeroes)
                .dropDestination(for: String.self) { (_: [String], _: CGPoint) -> Bool in
                    // Drop on All Heroes is ignored — need a specific hero target.
                    false
                }

                ForEach(viewModel.heroes) { hero in
                    let count = filteredAssignmentsForCounts(heroRecordName: hero.recordName).count
                    Button {
                        selection = .hero(hero.recordName)
                    } label: {
                        HStack {
                            Text(hero.displayName)
                            Spacer()
                            Text("\(count)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(QuestManagerView.SidebarSelection.hero(hero.recordName))
                    .dropDestination(for: String.self) { items, _ in
                        guard let templateRecordName = items.first,
                              let templateCache = viewModel.templates.first(where: { $0.recordName == templateRecordName })
                        else { return false }
                        // WHY snapshot: @Model rows cannot cross isolation; Sendable structs ride the Task.
                        let templateZoneID = appState.resolvedFamilyZoneID(fallbackRecord: templateCache)
                        let heroZoneID = appState.resolvedFamilyZoneID(fallbackRecord: hero)
                        let templateSnapshot = templateCache.toQuestTemplate(zoneID: templateZoneID)
                        let heroSnapshot = hero.toProfile(zoneID: heroZoneID)
                        onAssign(templateSnapshot, heroSnapshot)
                        return true
                    }
                }
            }

            Section("Templates") {
                let activeCount = filteredTemplatesForCounts(isActive: true).count
                Button {
                    selection = .templatesActive
                } label: {
                    HStack {
                        Label("Active", systemImage: "doc.fill")
                        Spacer()
                        Text("\(activeCount)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(QuestManagerView.SidebarSelection.templatesActive)
                let archivedCount = filteredTemplatesForCounts(isActive: false).count
                Button {
                    selection = .templatesArchived
                } label: {
                    HStack {
                        Label("Archived", systemImage: "archivebox")
                        Spacer()
                        Text("\(archivedCount)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(QuestManagerView.SidebarSelection.templatesArchived)
            }
        }
        .listStyle(.sidebar)
    }

    private func filteredTemplatesForCounts(isActive: Bool) -> [QuestTemplateCache] {
        let base = viewModel.templates.filter { $0.isActive == isActive }
        return applySearch(toTemplates: base)
    }

    private func filteredAssignmentsForCounts(heroRecordName: String?) -> [QuestCache] {
        let base: [QuestCache] = if let heroRecordName {
            viewModel.activeAssignments.filter { $0.assigneeRecordName == heroRecordName }
        } else {
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
