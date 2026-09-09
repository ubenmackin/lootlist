//
//  QuestManagerInspectorView.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import SwiftData
import SwiftUI

/// Inspector column extracted from QuestManagerView; keeps table context
/// visible while editing on iPad with no logic change.
struct QuestManagerInspectorView: View {
    @Environment(AppState.self) private var appState

    let viewModel: QuestManagerViewModel
    let selectedTemplateID: Set<PersistentIdentifier>
    let selectedAssignmentID: Set<PersistentIdentifier>
    let inspectorNewKind: QuestManagerView.InspectorNewKind?
    let onClear: () -> Void

    var body: some View {
        Group {
            if let kind = inspectorNewKind {
                switch kind {
                case .template:
                    TemplateManagerView(viewModel: viewModel, editing: nil, onCancel: {
                        onClear()
                    })
                case .assignment:
                    QuestAssignmentView(viewModel: viewModel, familyRecordName: appState.family?.id.recordName, onCancel: {
                        onClear()
                    })
                }
            } else if let tid = selectedTemplateID.first,
                      let cache = viewModel.templates.first(where: { $0.persistentModelID == tid })
            {
                TemplateManagerView(viewModel: viewModel, editing: cache, onCancel: {
                    onClear()
                })
            } else if let aid = selectedAssignmentID.first,
                      let cache = viewModel.activeAssignments.first(where: { $0.persistentModelID == aid })
            {
                let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: cache)
                let quest = cache.toQuest(zoneID: zoneID)
                QuestAssignmentView(mode: .edit(questRecordName: quest.id.recordName), viewModel: viewModel, familyRecordName: appState.family?.id.recordName, onCancel: {
                    onClear()
                })
            } else {
                ContentUnavailableView(
                    "Select a row",
                    systemImage: "sidebar.right",
                    description: Text("Choose a template or assignment to inspect. Drag a template onto a hero to assign it.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(DesignSystemConstants.Colors.background))
        .toolbar {
            if inspectorNewKind != nil || !selectedTemplateID.isEmpty || !selectedAssignmentID.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onClear()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close inspector")
                }
            }
        }
    }
}
