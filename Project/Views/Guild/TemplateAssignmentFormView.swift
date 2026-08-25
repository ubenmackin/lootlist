//
//  TemplateAssignmentFormView.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import SwiftUI

struct TemplateAssignmentFormView: View {
    @Bindable var viewModel: QuestManagerViewModel
    let isFromTemplateMode: Bool

    @Binding var selectedTemplate: QuestTemplateCache?
    @Binding var editQuestName: String
    @Binding var userEditedQuestName: Bool
    @Binding var selectedHero: ProfileCache?
    @Binding var goldOverrideText: String
    @Binding var xpOverrideText: String
    @Binding var approvalOverride: QuestAssignmentView.ApprovalModeSelection
    @Binding var isAllOrNothingOverride: Bool

    private var isMultiOccurrence: Bool {
        guard let template = selectedTemplate else { return false }
        return QuestSchedule.isMultiOccurrence(
            schedule: template.scheduleTypeEnum ?? .weeklyFlexible,
            targetCount: template.targetCount,
            specificDays: template.specificDays
        )
    }

    var body: some View {
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
                    guard isFromTemplateMode else { return }
                    editQuestName = newTemplate?.name ?? ""
                    userEditedQuestName = false
                    isAllOrNothingOverride = newTemplate?.isAllOrNothing ?? false
                }
            }
        }

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

        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reward Override")
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(["1.00", "2.50", "5.00"], id: \.self) { preset in
                            PresetPill(
                                text: CurrencyFormatter.string(Double(preset) ?? 0),
                                isSelected: goldOverrideText == preset,
                                action: { goldOverrideText = preset }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                TextField(
                    selectedTemplate.map { String(format: "%.2f", $0.goldReward) } ?? "",
                    text: $goldOverrideText
                )
                .keyboardType(.decimalPad)
            }

            HStack {
                Text("XP Override")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField(
                    selectedTemplate.map { String($0.xpReward) } ?? "",
                    text: $xpOverrideText
                )
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            }

            Picker("Approval", selection: $approvalOverride) {
                ForEach(QuestAssignmentView.ApprovalModeSelection.allCases) { sel in
                    Text(sel.rawValue).tag(sel)
                }
            }

            if isMultiOccurrence {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("All-or-Nothing", isOn: $isAllOrNothingOverride)
                    Text(
                        "When enabled, the hero must complete all required days or times to earn any gold or XP. When disabled, rewards are earned incrementally per completion."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Overrides (optional)")
        } footer: {
            Text("Leaving a field blank uses the template's default value.")
        }
    }
}
